public import PebbleProtocol
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    /// False when the store could not be read, and `timeline.reminders` is
    /// left as it was. An empty list in its place reads as "the reader deleted
    /// every reminder", and the synchronization after it takes them all off
    /// the watch.
    @discardableResult
    public func loadReminders() async -> Bool {
        do {
            timeline.reminders = try await reminderStore.pins()
            return true
        } catch {
            await DiagnosticLog.shared.record(
                .error,
                category: "timeline",
                message: "the reminders could not be read: \(String(reflecting: error))"
            )
            return false
        }
    }

    public func addReminder(title: String, date: Date) async {
        let reminder = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: date,
            title: title,
            subtitle: nil,
            body: nil,
            kind: .reminder
        )
        timeline.reminders.append(reminder)
        timeline.reminders.sort { $0.timestamp < $1.timestamp }
        do {
            try await reminderStore.save(timeline.reminders)
        } catch {
            timeline.reminders.removeAll { $0.id == reminder.id }
            timeline.reminderFeedback = .failure("The change could not be saved.")
            return
        }
        // The watch keeps a fifteen-minute window — `MAX_REMINDER_AGE` in
        // `reminder_db.c` — and refuses anything older outright, which the list
        // already says about the ones that have passed.
        guard reminder.timestamp > .now else {
            timeline.reminderFeedback = .success("That time has passed, so the reminder is kept here rather than sent to the watch.")
            return
        }
        timeline.reminderFeedback = nil
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
                timeline.reminderFeedback = .failure(
                    "\(connection.watch.name) did not accept the reminder. \(Text(refusalReason(for: error)))"
                )
                await DiagnosticLog.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.watch.name) refused a reminder: \(String(reflecting: error))"
                )
            }
        }
    }

    // Named rather than numbered: the list they were picked from is sorted and
    // split for reading.
    public func removeReminders(_ removed: [TimelinePin]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.id))
        timeline.reminders.removeAll { identifiers.contains($0.id) }
        let saved = (try? await reminderStore.save(timeline.reminders)) != nil
        // One reminder kept in two places is let go of in both: leaving the
        // Reminders app's copy behind would only have the next read put the
        // reminder back.
        await forgetInRemindersApp(identifiers)
        for connection in activeConnections {
            // Named here as well as swept, because one the watch made was never
            // written by this app and so is in nobody's record of what it holds.
            await removeRemindersTheWatchStillHas(on: connection, alsoRemoving: identifiers)
        }
        // After the watches rather than instead of them: the reader asked for
        // these to be gone, and only the phone's copy failed to hear it.
        if !saved {
            timeline.reminderFeedback = .failure("The change could not be saved.")
        }
    }

    /// Deletes the timeline.reminders this watch was given and the app no longer has.
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
        let forgotten = written.union(extra).subtracting(timeline.reminders.map(\.id))
        guard !forgotten.isEmpty else { return }
        var removed: Set<UUID> = []
        let client = connection.client
        for id in forgotten {
            do {
                try await retry(with: .watchWork) { try await client.remove(.timelineReminder(id)) }
                removed.insert(id)
            } catch {
                // Kept in the record, so the next connection asks again.
                await DiagnosticLog.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.watch.name) kept a reminder that is gone here: "
                        + String(reflecting: error)
                )
                break
            }
        }
        try? await reminderStore.setWrittenPinIDs(written.subtracting(removed), watchID: watchID)
        // Said whichever way it went, the way the pins are: BlobDB cannot be
        // listed, so this line is the only account of what left the watch. Only
        // a failure used to be recorded, which left two of six removes in one
        // on-watch log belonging to nobody.
        await DiagnosticLog.shared.record(
            category: "timeline",
            message: "\(connection.watch.name): removed \(removed.count)"
                + " of \(forgotten.count) reminder(s) the app no longer has"
        )
    }

    // One in the past has already been shown, or missed, and sending it would
    // only make the watch buzz for it now.
    func synchronizeReminders(on connection: WatchConnection) async {
        guard connection.isConnected, await loadReminders() else { return }
        await removeRemindersTheWatchStillHas(on: connection)
        let watchID = connection.watch.id
        var written = (try? await reminderStore.writtenPinIDs(watchID: watchID)) ?? []
        for reminder in timeline.reminders where reminder.timestamp > .now && !reminder.isFromWatch {
            do {
                try await connection.client.write(.timelineReminder(reminder))
                written.insert(reminder.id)
            } catch {
                await DiagnosticLog.shared.record(
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
