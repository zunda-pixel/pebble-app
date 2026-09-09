import Algorithms
import Defaults
public import PebbleProtocol
import AsyncAlgorithms
import EventKit
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func loadTimeline() async {
        do {
            let stored = try await timelineStore.pins()
            timeline.pins = Self.pinsUnderOneIdentifierEach(stored)
            // Two pins under one identifier is not a state anything downstream
            // can represent: BlobDB is keyed by it, so the watch keeps whichever
            // arrived last, and the record of what was written keeps one digest
            // for the key, so the others never match it and are sent on every
            // synchronization for ever. The reader's watch was being written 32
            // pins of 94 that way, and showing one week of a recurring event.
            let collapsed = stored.count - timeline.pins.count
            if collapsed > 0 {
                // Written back so the file stops holding them: otherwise every
                // load repairs the same thing again and the warning never stops.
                try? await timelineStore.save(timeline.pins)
                await PebbleDiagnostics.shared.record(
                    .warning,
                    category: "timeline",
                    message: "\(collapsed) of \(stored.count) pin(s) shared an identifier with another;"
                        + " the last of each was kept"
                )
            }
        } catch {
            timeline.feedback = .failure("Timeline could not be loaded.")
        }
    }

    /// The pins with one entry per identifier, keeping the last of each and the
    /// order they were in.
    ///
    /// The last rather than the first, because that is what a watch keyed by the
    /// identifier ends up holding and what the digest record ends up describing:
    /// collapsing them the same way is what makes the three agree.
    static func pinsUnderOneIdentifierEach(_ pins: [TimelinePin]) -> [TimelinePin] {
        var lastByID: [UUID: TimelinePin] = [:]
        for pin in pins { lastByID[pin.id] = pin }
        var seen: Set<UUID> = []
        return pins.compactMap { pin in
            guard seen.insert(pin.id).inserted else { return nil }
            return lastByID[pin.id]
        }
    }

    public func addTimelinePin(title: String, date: Date) async {
        let pin = TimelinePin(
            parentApplicationID: UUID(), timestamp: date, title: title, subtitle: nil, body: nil
        )
        timeline.pins.append(pin)
        do {
            try await timelineStore.save(timeline.pins)
        } catch {
            timeline.pins.removeAll { $0.id == pin.id }
            timeline.feedback = .failure("The timeline pin could not be saved.")
            return
        }
        // `synchronizeTimeline` derives an upsert for every pin it holds, so a queue
        // write that fails is not lost work.
        try? await queueTimelineOperation(.upsert(pin))
        if connectedWatch != nil {
            await synchronizeTimeline()
            timeline.feedback = .success("Timeline pin saved.")
        } else {
            timeline.feedback = .success("Timeline pin queued for the next connection.")
        }
    }

    // Named rather than numbered: the list they were picked from may be grouped
    // or narrowed by a search.
    public func removeTimelinePins(_ removed: [TimelinePin]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.id))
        timeline.pins.removeAll { identifiers.contains($0.id) }
        try? await timelineStore.save(timeline.pins)
        for pin in removed { try? await queueTimelineOperation(.delete(pin.id)) }
        if connectedWatch != nil { await synchronizeTimeline() }
    }

    public func synchronizeTimeline() async {
        await loadTimeline()
        guard !activeConnections.isEmpty else { return }
        let queued = (try? await pendingTimelineOperationStore.operations()) ?? []
        let queuedUpserts = Set(queued.compactMap { operation -> UUID? in
            if case .upsert(let pin) = operation { return pin.id }
            return nil
        })
        // A watch that stopped part-way keeps the rest of the queue for its next
        // connection, and so does every other watch: whatever the least
        // finished one did not get is what is kept.
        var firstUnfinished = queued.count
        for connection in activeConnections {
            // What the reconciliation took off this watch, so the queue does not
            // ask for it a second time: deleting a pin used to cost two removes,
            // one from each.
            let alreadyGone = await removePinsTheAppHasForgotten(on: connection)
            // Derived per watch, because what each already holds is its own: the
            // queue is the durable work and goes first, so an index into it
            // keeps its meaning however many pins this watch still needs.
            let derived = await upsertsStillNeeded(besides: queuedUpserts, on: connection)
            let stopped = await send(
                queued + derived,
                to: connection,
                queuedCount: queued.count,
                alreadyGone: alreadyGone
            )
            firstUnfinished = min(firstUnfinished, min(stopped, queued.count))
        }
        try? await pendingTimelineOperationStore.save(Array(queued[firstUnfinished...]))
    }

    /// The pins this watch does not already hold, as upserts.
    ///
    /// Without this every synchronization wrote every pin the app held — 93 of
    /// them on the reader's watch, three times in 47 seconds — re-sending the
    /// same bytes to the same keys. The app glances have always compared what
    /// they last sent; this is the same idea, kept on disk because it has to
    /// survive a launch.
    private func upsertsStillNeeded(
        besides queuedUpserts: Set<UUID>,
        on connection: WatchConnection
    ) async -> [PendingTimelineOperation] {
        let written = (try? await timelineStore.writtenPinDigests(watchID: connection.watch.id)) ?? [:]
        return timeline.pins
            .filter { pin in
                // A pin the watch made is already on the watch, with actions and
                // an icon this app does not model: writing it back would replace
                // it with less.
                guard !queuedUpserts.contains(pin.id), !pin.isFromWatch else { return false }
                return written[pin.id] != pin.writtenDigest
            }
            .map(PendingTimelineOperation.upsert)
    }

    /// Sends the operations to one watch and answers the index it stopped at.
    ///
    /// `queuedCount` names the prefix that came from the queue rather than from
    /// the digests, and is only used to say which in the log. Without it a
    /// count on its own cannot tell a queue that is not draining from digests
    /// that are not matching, which is exactly the question a synchronization
    /// that keeps sending the same number of pins raises.
    ///
    /// `alreadyGone` names what the reconciliation has just taken off this
    /// watch. A queued delete for one of those is done rather than skipped:
    /// the pin is off the watch, which is all the queue was asking for.
    private func send(
        _ operations: [PendingTimelineOperation],
        to connection: WatchConnection,
        queuedCount: Int,
        alreadyGone: Set<UUID>
    ) async -> Int {
        let client = connection.client
        var taken = 0
        var takenFromQueue = 0
        var dropped = 0
        for (index, operation) in operations.indexed() {
            do {
                switch operation {
                case .upsert(let pin):
                    try await retry(with: .watchWork) { try await client.write(.timelinePin(pin)) }
                    taken += 1
                    if index < queuedCount { takenFromQueue += 1 }
                case .delete(let id):
                    // Counted by the reconciliation's own line, not here: one
                    // pin leaving should read as one pin leaving.
                    guard !alreadyGone.contains(id) else { continue }
                    try await retry(with: .watchWork) { try await client.remove(.timelinePin(id)) }
                    dropped += 1
                }
            } catch {
                return index
            }
        }
        // This watch now holds exactly what the app holds, which is what makes
        // the reconciliation above possible next time — and, by the digests,
        // what makes the next synchronization write only what changed.
        try? await timelineStore.setWrittenPinDigests(
            Dictionary(
                timeline.pins.map { ($0.id, $0.writtenDigest) },
                uniquingKeysWith: { _, latest in latest }
            ),
            watchID: connection.watch.id
        )
        // Nothing to say when there was nothing to send: this runs on every
        // connection.
        if taken + dropped > 0 {
            await PebbleDiagnostics.shared.record(
                category: "timeline",
                message: "\(connection.watch.name) took \(taken) of \(timeline.pins.count) pin(s)"
                    + " — \(takenFromQueue) queued, \(taken - takenFromQueue) derived"
                    + " — and dropped \(dropped)"
            )
        }
        return operations.count
    }

    /// Deletes the pins this watch was given and the app no longer has, and
    /// answers which ones went.
    ///
    /// BlobDB has no listing, so a pin can only be named from the app's own
    /// record of what it wrote. Without this, a pin whose delete was never
    /// queued — the queue was full, the app was reinstalled, the moment was
    /// missed — stays on the watch's timeline and is never mentioned again.
    ///
    /// The answer matters because the queue usually holds a delete for the same
    /// pin: letting go of one from the phone puts it in both places at once.
    private func removePinsTheAppHasForgotten(on connection: WatchConnection) async -> Set<UUID> {
        let watchID = connection.watch.id
        let written = (try? await timelineStore.writtenPinDigests(watchID: watchID)) ?? [:]
        let forgotten = Set(written.keys).subtracting(timeline.pins.map(\.id))
        guard !forgotten.isEmpty else { return [] }
        var removed: Set<UUID> = []
        let client = connection.client
        for id in forgotten {
            do {
                try await retry(with: .watchWork) { try await client.remove(.timelinePin(id)) }
                removed.insert(id)
            } catch {
                break
            }
        }
        // The digests of the pins that stayed are kept: they are still what the
        // watch holds, and re-deriving them would send every one again.
        try? await timelineStore.setWrittenPinDigests(
            written.filter { !removed.contains($0.key) },
            watchID: watchID
        )
        await PebbleDiagnostics.shared.record(
            category: "timeline",
            message: "\(connection.watch.name): removed \(removed.count)"
                + " of \(forgotten.count) pin(s) the app no longer has"
        )
        return removed
    }

    /// Empties the watch's own pin database and writes back what the app holds.
    ///
    /// The reconciliation above can only name pins the app remembers writing.
    /// After a reinstall it remembers nothing, and this is the only way to reach
    /// what is left — at the cost of removing pins from any other source too,
    /// which is why it is asked for rather than done.
    public func clearWatchTimeline(watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            diagnostics.feedback[.timeline] = .failure("Connect the watch before clearing its timeline.")
            return
        }
        do {
            try await connection.client.remove(.allTimelinePins)
        } catch {
            diagnostics.feedback[.timeline] = .failure(
                "\(connection.watch.name) did not clear its timeline. \(Text(refusalReason(for: error)))"
            )
            return
        }
        try? await timelineStore.forgetWrittenPinIDs(watchID: connection.watch.id)
        await PebbleDiagnostics.shared.record(
            .warning,
            category: "timeline",
            message: "\(connection.watch.name): cleared the pin database"
        )
        diagnostics.feedback[.timeline] = .progress("The watch's timeline was cleared. Sending what the app has…")
        await synchronizeTimeline()
        diagnostics.feedback[.timeline] = .success("The watch's timeline was cleared and written again from the app.")
    }

    func queueTimelineOperation(_ operation: PendingTimelineOperation) async throws {
        var operations = try await pendingTimelineOperationStore.operations()
        let id: UUID
        switch operation {
        case .upsert(let pin): id = pin.id
        case .delete(let value): id = value
        }
        operations.removeAll { existing in
            switch existing {
            case .upsert(let pin): pin.id == id
            case .delete(let value): value == id
            }
        }
        operations.append(operation)
        trimQueuedOperations(&operations)
        try await pendingTimelineOperationStore.save(operations)
    }

    /// An upsert is reconstructable — `synchronizeTimeline` derives one for every
    /// pin — and a delete is not: nothing else remembers a pin the phone has
    /// already let go of.
    func trimQueuedOperations(_ operations: inout [PendingTimelineOperation]) {
        let cap = 200
        guard operations.count > cap else { return }
        var droppable = operations.count - cap
        operations.removeAll { operation in
            guard droppable > 0, case .upsert = operation else { return false }
            droppable -= 1
            return true
        }
        if operations.count > cap {
            timeline.feedback = .failure(
                "The timeline queue is full. \(operations.count - cap) removed event(s) are still waiting for the watch."
            )
        }
    }

    /// The calendar pins whose bytes differ from the ones they replace.
    ///
    /// The queue carries a change and `synchronizeTimeline` does not second-guess
    /// what is in it, so queueing every pin on every calendar read put all of
    /// them past the comparison that would otherwise have skipped them: an
    /// on-device synchronization wrote 32 unchanged pins that way, once per
    /// `EKEventStoreChanged`, which one edited event is enough to raise.
    ///
    /// What the watch is missing is not this decision's business — the pins are
    /// derived from the digests for that, and a pin dropped here because nothing
    /// about it changed is picked up there if the watch never got it.
    static func calendarPinsWorthQueueing(
        _ current: [TimelinePin],
        replacing previous: [TimelinePin]
    ) -> [TimelinePin] {
        let digests = Dictionary(
            previous.map { ($0.id, $0.writtenDigest) },
            uniquingKeysWith: { _, latest in latest }
        )
        return current.filter { digests[$0.id] != $0.writtenDigest }
    }

    /// Reads the calendar list for the settings screen, bringing the stored
    /// preferences' identifiers along — EventKit may have reissued them.
    public func loadCalendars() async {
        guard let calendars = try? await calendarBridge.calendars() else { return }
        timeline.calendars = calendars
        Defaults[.calendarPreferences] = CalendarPreference.migrated(
            Defaults[.calendarPreferences],
            against: calendars
        )
    }

    func isCalendarEnabled(_ calendar: PhoneCalendar) -> Bool {
        Defaults[.calendarPreferences].first { $0.matches(calendar) }?.isEnabled ?? true
    }

    func setCalendarEnabled(_ calendar: PhoneCalendar, _ isEnabled: Bool) async {
        var preferences = Defaults[.calendarPreferences]
        if let index = preferences.firstIndex(where: { $0.matches(calendar) }) {
            preferences[index].isEnabled = isEnabled
            preferences[index].identifier = calendar.id
        } else {
            preferences.append(CalendarPreference(
                identifier: calendar.id,
                title: calendar.title,
                sourceTitle: calendar.sourceTitle,
                isEnabled: isEnabled
            ))
        }
        Defaults[.calendarPreferences] = preferences
        // The pins of a calendar just switched off vanish from the fetch, and
        // vanishing is what queues their deletion.
        await synchronizeCalendar()
    }

    public func setCalendarPinsEnabled(_ enabled: Bool) async {
        Defaults[.calendarPinsEnabled] = enabled
        await synchronizeCalendar()
    }

    public func setCalendarIncludesDeclined(_ included: Bool) async {
        Defaults[.calendarIncludesDeclined] = included
        await synchronizeCalendar()
    }

    public func setCalendarRemindersEnabled(_ enabled: Bool) async {
        Defaults[.calendarRemindersEnabled] = enabled
        await synchronizeCalendar()
    }

    public func synchronizeCalendar() async {
        do {
            // The master switch empties the fetch rather than skipping the
            // sync: absence is what queues the deletions, on the watch too.
            let calendarPins: [TimelinePin]
            let calendarReminders: [TimelinePin]
            if Defaults[.calendarPinsEnabled] {
                // The list is read here and not only on the settings screen,
                // because the disabled set has to be derived from what EventKit
                // holds *now* — a sync running off a list nobody had opened yet
                // would see no calendars and disable none.
                let calendars = try await calendarBridge.calendars()
                timeline.calendars = calendars
                let disabled = Set(calendars.map(\.id)).subtracting(
                    CalendarPreference.enabledIdentifiers(
                        of: calendars,
                        given: Defaults[.calendarPreferences]
                    )
                )
                (calendarPins, calendarReminders) = try await calendarBridge.timelinePins(
                    disabledCalendarIdentifiers: disabled,
                    includeDeclined: Defaults[.calendarIncludesDeclined],
                    remindersEnabled: Defaults[.calendarRemindersEnabled]
                )
            } else {
                calendarPins = []
                calendarReminders = []
            }
            try await calendarReminderStore.save(calendarReminders)
            let oldCalendarPins = timeline.pins.filter { $0.parentApplicationID == CalendarBridge.calendarApplicationID }

            timeline.pins.removeAll { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timeline.pins.append(contentsOf: calendarPins)
            try await timelineStore.save(timeline.pins)
            let newIDs = Set(calendarPins.map(\.id))
            for pin in oldCalendarPins where !newIDs.contains(pin.id) {
                try await queueTimelineOperation(.delete(pin.id))
            }
            for pin in Self.calendarPinsWorthQueueing(calendarPins, replacing: oldCalendarPins) {
                try await queueTimelineOperation(.upsert(pin))
            }
            if connectedWatch != nil { await synchronizeTimeline() }
            // After the pins: a reminder's parent is its pin, which the watch
            // reads back for the snooze arithmetic.
            for connection in activeConnections {
                await synchronizeCalendarReminders(on: connection)
            }
            timeline.feedback = .success("Calendar synchronized with Timeline.")
        } catch { timeline.feedback = .failure("Calendar access or synchronization failed.") }
    }

    /// Brings this watch's Reminder database to the calendar reminders the app
    /// holds: what vanished is removed, what changed or never arrived is
    /// written, and what the watch already holds — by the digest of the bytes
    /// it was written as — costs nothing.
    ///
    /// No queue, unlike the pins: every calendar read replaces the whole set,
    /// so the store itself is the durable record and absence from it is what
    /// names a deletion.
    func synchronizeCalendarReminders(on connection: WatchConnection) async {
        guard connection.isConnected else { return }
        let reminders = (try? await calendarReminderStore.pins()) ?? []
        let watchID = connection.watch.id
        var digests = (try? await calendarReminderStore.writtenPinDigests(watchID: watchID)) ?? [:]
        let current = Set(reminders.map(\.id))
        let client = connection.client
        var removed = 0
        var written = 0
        do {
            for id in digests.keys where !current.contains(id) {
                try await retry(with: .watchWork) { try await client.remove(.timelineReminder(id)) }
                digests[id] = nil
                removed += 1
            }
            // One in the past has already buzzed or been missed — `reminder_db.c`
            // refuses anything older than fifteen minutes outright.
            for reminder in reminders where reminder.timestamp > .now {
                guard digests[reminder.id] != reminder.writtenDigest else { continue }
                try await retry(with: .watchWork) { try await client.write(.timelineReminder(reminder)) }
                digests[reminder.id] = reminder.writtenDigest
                written += 1
            }
        } catch {
            // The digests written below only claim what got through; the next
            // connection picks up the rest.
            await PebbleDiagnostics.shared.record(
                .error,
                category: "timeline",
                message: "\(connection.watch.name) refused a calendar reminder: \(String(reflecting: error))"
            )
        }
        try? await calendarReminderStore.setWrittenPinDigests(digests, watchID: watchID)
        if removed + written > 0 {
            await PebbleDiagnostics.shared.record(
                category: "timeline",
                message: "\(connection.watch.name) took \(written) calendar reminder(s) and dropped \(removed)"
            )
        }
    }

    /// One store, one notification: EventKit says a calendar or a reminder
    /// changed without saying which, so both are read again.
    func observeEventKitChanges() {
        calendarChangesTask?.cancel()
        calendarChangesTask = Task { [weak self] in
            // EventKit reports a change per store write, so editing one event arrives as
            // a burst, each of which would re-read every calendar.
            let ticks = AsyncStream<Void> { continuation in
                let observation = Task {
                    for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                        continuation.yield(())
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in observation.cancel() }
            }
            for await _ in ticks.debounce(for: .seconds(2)) {
                guard !Task.isCancelled else { return }
                await self?.synchronizeCalendar()
                await self?.synchronizeRemindersApp()
            }
        }
    }
}
