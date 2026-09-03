import Algorithms
public import PebbleProtocol
import AsyncAlgorithms
import EventKit
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func loadTimeline() async {
        do { timelinePins = try await timelineLibrary.pins() }
        catch { dataSyncStatusMessage = "Timeline could not be loaded." }
    }

    public func addTimelinePin(title: String, date: Date) async {
        let pin = PebbleTimelinePin(
            parentApplicationID: UUID(), timestamp: date, title: title, subtitle: nil, body: nil
        )
        timelinePins.append(pin)
        do {
            try await timelineLibrary.save(timelinePins)
        } catch {
            timelinePins.removeAll { $0.id == pin.id }
            dataSyncStatusMessage = "The timeline pin could not be saved."
            return
        }
        // `synchronizeTimeline` derives an upsert for every pin it holds, so a queue
        // write that fails is not lost work.
        try? await queueTimelineOperation(.upsert(pin))
        if connectedDevice != nil {
            await synchronizeTimeline()
            dataSyncStatusMessage = "Timeline pin saved."
        } else {
            dataSyncStatusMessage = "Timeline pin queued for the next connection."
        }
    }

    // Named rather than numbered: the list they were picked from may be grouped
    // or narrowed by a search.
    public func removeTimelinePins(_ removed: [PebbleTimelinePin]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.id))
        timelinePins.removeAll { identifiers.contains($0.id) }
        try? await timelineLibrary.save(timelinePins)
        for pin in removed { try? await queueTimelineOperation(.delete(pin.id)) }
        if connectedDevice != nil { await synchronizeTimeline() }
    }

    public func synchronizeTimeline() async {
        await loadTimeline()
        guard !activeConnections.isEmpty else { return }
        var operations = (try? await pendingTimelineOperationLibrary.operations()) ?? []
        let queuedUpserts = Set(operations.compactMap { operation -> UUID? in
            if case .upsert(let pin) = operation { return pin.id }
            return nil
        })
        // A pin the watch made is already on the watch, with actions and an icon
        // this app does not model: writing it back would replace it with less.
        operations += timelinePins
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
        try? await pendingTimelineOperationLibrary.save(Array(operations[firstUnfinished...]))
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
                    try await retry(with: .watchWork) { try await client.upsertTimelinePin(pin) }
                case .delete(let id):
                    try await retry(with: .watchWork) { try await client.deleteTimelinePin(id: id) }
                }
            } catch {
                return index
            }
        }
        // This watch now holds exactly what the app holds, which is what makes
        // the reconciliation above possible next time.
        try? await timelineLibrary.setWrittenPinIDs(
            Set(timelinePins.map(\.id)),
            deviceID: connection.device.id
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
        let deviceID = connection.device.id
        let written = (try? await timelineLibrary.writtenPinIDs(deviceID: deviceID)) ?? []
        let forgotten = written.subtracting(timelinePins.map(\.id))
        guard !forgotten.isEmpty else { return }
        var removed: Set<UUID> = []
        let client = connection.client
        for id in forgotten {
            do {
                try await retry(with: .watchWork) { try await client.deleteTimelinePin(id: id) }
                removed.insert(id)
            } catch {
                break
            }
        }
        try? await timelineLibrary.setWrittenPinIDs(written.subtracting(removed), deviceID: deviceID)
        await PebbleDiagnostics.shared.record(
            category: "timeline",
            message: "\(connection.device.name): removed \(removed.count)"
                + " of \(forgotten.count) pin(s) the app no longer has"
        )
    }

    /// Empties the watch's own pin database and writes back what the app holds.
    ///
    /// The reconciliation above can only name pins the app remembers writing.
    /// After a reinstall it remembers nothing, and this is the only way to reach
    /// what is left — at the cost of removing pins from any other source too,
    /// which is why it is asked for rather than done.
    public func clearWatchTimeline(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            watchDiagnosticsStatusMessages[.timeline] = "Connect the watch before clearing its timeline."
            return
        }
        do {
            try await connection.client.clearTimelinePins()
        } catch {
            watchDiagnosticsStatusMessages[.timeline] =
                "\(connection.device.name) did not clear its timeline. \(Text(refusalReason(for: error)))"
            return
        }
        try? await timelineLibrary.forgetWrittenPinIDs(deviceID: connection.device.id)
        await PebbleDiagnostics.shared.record(
            .warning,
            category: "timeline",
            message: "\(connection.device.name): cleared the pin database"
        )
        watchDiagnosticsStatusMessages[.timeline] = "The watch's timeline was cleared. Sending what the app has…"
        await synchronizeTimeline()
        watchDiagnosticsStatusMessages[.timeline] = "The watch's timeline was cleared and written again from the app."
    }

    func queueTimelineOperation(_ operation: PendingTimelineOperation) async throws {
        var operations = try await pendingTimelineOperationLibrary.operations()
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
        try await pendingTimelineOperationLibrary.save(operations)
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
            dataSyncStatusMessage =
                "The timeline queue is full. \(operations.count - cap) removed event(s) are still waiting for the watch."
        }
    }

    public func synchronizeCalendar() async {
        do {
            let calendarPins = try await calendarBridge.timelinePins()
            let oldCalendarPins = timelinePins.filter { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.removeAll { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.append(contentsOf: calendarPins)
            try await timelineLibrary.save(timelinePins)
            let newIDs = Set(calendarPins.map(\.id))
            for pin in oldCalendarPins where !newIDs.contains(pin.id) {
                try await queueTimelineOperation(.delete(pin.id))
            }
            for pin in calendarPins { try await queueTimelineOperation(.upsert(pin)) }
            if connectedDevice != nil { await synchronizeTimeline() }
            dataSyncStatusMessage = "Calendar synchronized with Timeline."
        } catch { dataSyncStatusMessage = "Calendar access or synchronization failed." }
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
