public import API
public import Foundation
import SwiftUI

/// Reminders the watch buzzes for at a set time.
///
/// A reminder is the same record as a timeline pin in a database of its own.
/// The difference is what the watch does with it: a pin is something to find on
/// the timeline, a reminder is something the watch brings up when its moment
/// arrives. The watch keeps a window of them — a few days either side of now —
/// and drops the rest, so old ones need no tidying here.
extension AppModel {
    public func loadReminders() async {
        reminders = (try? await reminderLibrary.pins()) ?? []
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
        try? await reminderLibrary.save(reminders)
        for connection in activeConnections {
            do {
                try await connection.client.upsertTimelineReminder(reminder)
            } catch {
                reminderStatusMessage = "\(connection.device.name) did not accept the reminder. \(error.localizedDescription)"
            }
        }
    }

    /// Forgets these reminders, here and on every watch that holds them.
    ///
    /// Named rather than numbered: the list they were picked from is sorted and
    /// split for reading, so a row's place on screen is not its place here.
    public func removeReminders(_ removed: [PebbleTimelinePin]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.id))
        reminders.removeAll { identifiers.contains($0.id) }
        try? await reminderLibrary.save(reminders)
        for reminder in removed {
            for connection in activeConnections {
                try? await connection.client.deleteTimelineReminder(id: reminder.id)
            }
        }
    }

    /// Writes the reminders that are still ahead to a watch that has just
    /// connected. One in the past has already been shown, or missed, and
    /// sending it would only make the watch buzz about yesterday.
    func synchronizeReminders(on connection: WatchConnection) async {
        guard connection.isConnected else { return }
        await loadReminders()
        for reminder in reminders where reminder.timestamp > .now {
            do {
                try await connection.client.upsertTimelineReminder(reminder)
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "timeline",
                    message: "\(connection.device.name) rejected a reminder: \(String(reflecting: error))"
                )
                return
            }
        }
    }
}
