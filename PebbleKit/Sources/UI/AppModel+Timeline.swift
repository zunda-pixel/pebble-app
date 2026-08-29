import API
import AsyncAlgorithms
import EventKit
import Foundation

/// Timeline pins, and the calendar they are drawn from.
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
            try await queueTimelineOperation(.upsert(pin))
            if connectedDevice != nil { await synchronizeTimeline() }
            dataSyncStatusMessage = "Timeline pin saved."
        } catch { dataSyncStatusMessage = "Timeline pin queued for the next connection." }
    }

    public func removeTimelinePins(at offsets: IndexSet) async {
        let removed = offsets.compactMap { timelinePins.indices.contains($0) ? timelinePins[$0] : nil }
        timelinePins.remove(atOffsets: offsets)
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
        operations += timelinePins.filter { !queuedUpserts.contains($0.id) }.map(PendingTimelineOperation.upsert)
        var remaining: [PendingTimelineOperation] = []
        for (index, operation) in operations.enumerated() {
            do {
                for connection in activeConnections {
                    let client = connection.client
                    switch operation {
                    case .upsert(let pin):
                        try await PebbleRetryPolicy().execute { try await client.upsertTimelinePin(pin) }
                    case .delete(let id):
                        try await PebbleRetryPolicy().execute { try await client.deleteTimelinePin(id: id) }
                    }
                }
            } catch {
                remaining.append(contentsOf: operations[index...])
                break
            }
        }
        try? await pendingTimelineOperationLibrary.save(remaining)
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
        if operations.count > 200 {
            operations.removeFirst(operations.count - 200)
        }
        try await pendingTimelineOperationLibrary.save(operations)
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

    func observeCalendarChanges() {
        calendarChangesTask?.cancel()
        calendarChangesTask = Task { [weak self] in
            // EventKit reports a change per store write, so editing one event
            // arrives as a burst. Each one would otherwise re-read every
            // calendar and rewrite the watch's timeline, so wait for the burst
            // to settle. Only the fact that something changed matters, which is
            // also what makes these ticks safe to hand to `debounce`.
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
            }
        }
    }
}
