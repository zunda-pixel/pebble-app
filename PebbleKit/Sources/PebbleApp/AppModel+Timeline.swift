import Algorithms
public import PebbleProtocol
import AsyncAlgorithms
import EventKit
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func loadTimeline() async {
        do { timeline.pins = try await timelineStore.pins() }
        catch { timeline.feedback = .failure("Timeline could not be loaded.") }
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
        var operations = (try? await pendingTimelineOperationStore.operations()) ?? []
        let queuedUpserts = Set(operations.compactMap { operation -> UUID? in
            if case .upsert(let pin) = operation { return pin.id }
            return nil
        })
        // A pin the watch made is already on the watch, with actions and an icon
        // this app does not model: writing it back would replace it with less.
        operations += timeline.pins
            .filter { !queuedUpserts.contains($0.id) && !$0.isFromWatch }
            .map(PendingTimelineOperation.upsert)
        // A watch that stopped part-way keeps the rest of the queue for its next
        // connection, and so does every other watch: whatever the least
        // finished one did not get is what is kept.
        var firstUnfinished = operations.count
        for connection in activeConnections {
            await removePinsTheAppHasForgotten(on: connection)
            firstUnfinished = min(firstUnfinished, await send(operations, to: connection))
        }
        try? await pendingTimelineOperationStore.save(Array(operations[firstUnfinished...]))
    }

    /// Sends the operations to one watch and answers the index it stopped at.
    private func send(
        _ operations: [PendingTimelineOperation],
        to connection: WatchConnection
    ) async -> Int {
        let client = connection.client
        for (index, operation) in operations.indexed() {
            do {
                switch operation {
                case .upsert(let pin):
                    try await retry(with: .watchWork) { try await client.write(.timelinePin(pin)) }
                case .delete(let id):
                    try await retry(with: .watchWork) { try await client.remove(.timelinePin(id)) }
                }
            } catch {
                return index
            }
        }
        // This watch now holds exactly what the app holds, which is what makes
        // the reconciliation above possible next time.
        try? await timelineStore.setWrittenPinIDs(
            Set(timeline.pins.map(\.id)),
            watchID: connection.watch.id
        )
        return operations.count
    }

    /// Deletes the pins this watch was given and the app no longer has.
    ///
    /// BlobDB has no listing, so a pin can only be named from the app's own
    /// record of what it wrote. Without this, a pin whose delete was never
    /// queued — the queue was full, the app was reinstalled, the moment was
    /// missed — stays on the watch's timeline and is never mentioned again.
    private func removePinsTheAppHasForgotten(on connection: WatchConnection) async {
        let watchID = connection.watch.id
        let written = (try? await timelineStore.writtenPinIDs(watchID: watchID)) ?? []
        let forgotten = written.subtracting(timeline.pins.map(\.id))
        guard !forgotten.isEmpty else { return }
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
        try? await timelineStore.setWrittenPinIDs(written.subtracting(removed), watchID: watchID)
        await PebbleDiagnostics.shared.record(
            category: "timeline",
            message: "\(connection.watch.name): removed \(removed.count)"
                + " of \(forgotten.count) pin(s) the app no longer has"
        )
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

    public func synchronizeCalendar() async {
        do {
            let calendarPins = try await calendarBridge.timelinePins()
            let oldCalendarPins = timeline.pins.filter { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timeline.pins.removeAll { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timeline.pins.append(contentsOf: calendarPins)
            try await timelineStore.save(timeline.pins)
            let newIDs = Set(calendarPins.map(\.id))
            for pin in oldCalendarPins where !newIDs.contains(pin.id) {
                try await queueTimelineOperation(.delete(pin.id))
            }
            for pin in calendarPins { try await queueTimelineOperation(.upsert(pin)) }
            if connectedWatch != nil { await synchronizeTimeline() }
            timeline.feedback = .success("Calendar synchronized with Timeline.")
        } catch { timeline.feedback = .failure("Calendar access or synchronization failed.") }
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
