import Algorithms
public import API
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
        operations += timelinePins.filter { !queuedUpserts.contains($0.id) }.map(PendingTimelineOperation.upsert)
        var remaining: [PendingTimelineOperation] = []
        for (index, operation) in operations.indexed() {
            do {
                for connection in activeConnections {
                    let client = connection.client
                    switch operation {
                    case .upsert(let pin):
                        try await retry(with: .watchWork) { try await client.upsertTimelinePin(pin) }
                    case .delete(let id):
                        try await retry(with: .watchWork) { try await client.deleteTimelinePin(id: id) }
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

    func observeCalendarChanges() {
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
            }
        }
    }
}
