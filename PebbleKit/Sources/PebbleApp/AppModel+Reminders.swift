public import PebbleProtocol
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func loadReminders() async {
        reminders = (try? await reminderStore.pins()) ?? []
    }

    public func addReminder(title: String, date: Date) async {
        let reminder = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: date,
            title: title,
            subtitle: nil,
            body: nil,
            kind: .reminder
        )
        reminders.append(reminder)
        reminders.sort { $0.timestamp < $1.timestamp }
        try? await reminderStore.save(reminders)
        // The watch keeps a fifteen-minute window — `MAX_REMINDER_AGE` in
        // `reminder_db.c` — and refuses anything older outright, which the list
        // already says about the ones that have passed.
        guard reminder.timestamp > .now else {
            reminderStatusMessage = "That time has passed, so the reminder is kept here rather than sent to the watch."
            return
        }
        reminderStatusMessage = nil
        for connection in activeConnections {
            do {
                try await connection.client.write(.timelineReminder(reminder))
                // Written down before it can be deleted: a reminder added,
                // then deleted while the watch is away, is one only this record
                // can name when the watch comes back.
                let watchID = connection.watch.id
                var written = (try? await reminderStore.writtenPinIDs(watchID: watchID)) ?? []
                written.insert(reminder.id)
                try? await reminderStore.setWrittenPinIDs(written, watchID: watchID)
            } catch {
                reminderStatusMessage =
                    "\(connection.watch.name) did not accept the reminder. \(Text(refusalReason(for: error)))"
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.watch.name) refused a reminder: \(String(reflecting: error))"
                )
            }
        }
    }

    // Named rather than numbered: the list they were picked from is sorted and
    // split for reading.
    public func removeReminders(_ removed: [PebbleTimelinePin]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.id))
        reminders.removeAll { identifiers.contains($0.id) }
        try? await reminderStore.save(reminders)
        // One reminder kept in two places is let go of in both: leaving the
        // Reminders app's copy behind would only have the next read put the
        // reminder back.
        await forgetInRemindersApp(identifiers)
        for connection in activeConnections {
            // Named here as well as swept, because one the watch made was never
            // written by this app and so is in nobody's record of what it holds.
            await removeRemindersTheWatchStillHas(on: connection, alsoRemoving: identifiers)
        }
    }

    /// Deletes the reminders this watch was given and the app no longer has.
    ///
    /// A reminder let go of while the watch was away used to be let go of here
    /// too: the delete went to every connected watch and, when there were none,
    /// to nobody. Nothing said it again, and the watch went on buzzing for a
    /// reminder the reader had thrown away. BlobDB cannot be listed, so what
    /// this app wrote is the only record of what to take back.
    func removeRemindersTheWatchStillHas(
        on connection: WatchConnection,
        alsoRemoving extra: Set<UUID> = []
    ) async {
        let watchID = connection.watch.id
        let written = (try? await reminderStore.writtenPinIDs(watchID: watchID)) ?? []
        let forgotten = written.union(extra).subtracting(reminders.map(\.id))
        guard !forgotten.isEmpty else { return }
        var removed: Set<UUID> = []
        let client = connection.client
        for id in forgotten {
            do {
                try await retry(with: .watchWork) { try await client.remove(.timelineReminder(id)) }
                removed.insert(id)
            } catch {
                // Kept in the record, so the next connection asks again.
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.watch.name) kept a reminder that is gone here: "
                        + String(reflecting: error)
                )
                break
            }
        }
        try? await reminderStore.setWrittenPinIDs(written.subtracting(removed), watchID: watchID)
    }

    // One in the past has already been shown, or missed, and sending it would
    // only make the watch buzz for it now.
    func synchronizeReminders(on connection: WatchConnection) async {
        guard connection.isConnected else { return }
        await loadReminders()
        await removeRemindersTheWatchStillHas(on: connection)
        let watchID = connection.watch.id
        var written = (try? await reminderStore.writtenPinIDs(watchID: watchID)) ?? []
        for reminder in reminders where reminder.timestamp > .now && !reminder.isFromWatch {
            do {
                try await connection.client.write(.timelineReminder(reminder))
                written.insert(reminder.id)
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.watch.name) rejected a reminder: \(String(reflecting: error))"
                )
                break
            }
        }
        // Whatever got through, so that a reminder deleted before the next
        // connection can still be named.
        try? await reminderStore.setWrittenPinIDs(written, watchID: watchID)
    }
}
