import PebbleProtocol
import Foundation
import SwiftUI

extension AppModel {
    /// Brings the phone's Reminders app and the watch to the same reminders.
    ///
    /// What the watch made goes there first, so that the reading which follows
    /// finds it and does not take it for one the reader has finished with.
    public func synchronizeRemindersApp() async {
        await loadReminders()
        for reminder in reminders where reminder.isFromWatch && reminder.timestamp > .now {
            await mirrorInRemindersApp(reminder)
        }
        let items: [RemindersAppItem]
        do {
            items = try await remindersAppStore.reminders()
        } catch {
            reminderStatusMessage = "The Reminders app could not be read."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "timeline",
                message: "the Reminders app could not be read: \(String(reflecting: error))"
            )
            return
        }
        var mirrored = (try? await reminderStore.mirroredIdentifiers()) ?? [:]
        let outcome = RemindersAppSync.merged(
            kept: reminders,
            fromApp: items,
            mirrored: mirrored,
            now: .now
        )
        reminders = outcome.reminders
        // Named for both directions: what came from the Reminders app is named
        // here too, so letting go of it in this app can reach it there.
        for item in items { mirrored[item.reminder.id] = item.identifier }
        for reminder in outcome.finished { mirrored[reminder.id] = nil }
        try? await reminderStore.save(reminders)
        try? await reminderStore.setMirroredIdentifiers(mirrored)
        reminderStatusMessage = nil
        for connection in activeConnections {
            await synchronizeReminders(on: connection)
        }
    }

    /// Copies a reminder the watch made into the phone's Reminders app.
    ///
    /// A reminder dictated to the watch is only on the watch, and the watch
    /// keeps a window: once its time has passed it is gone from there and there
    /// was nowhere else it was written down.
    func mirrorInRemindersApp(_ reminder: PebbleTimelinePin) async {
        var mirrored = (try? await reminderStore.mirroredIdentifiers()) ?? [:]
        do {
            if let identifier = mirrored[reminder.id] {
                try await remindersAppStore.update(reminder, identifier: identifier)
                return
            }
            mirrored[reminder.id] = try await remindersAppStore.add(reminder)
            try await reminderStore.setMirroredIdentifiers(mirrored)
        } catch {
            await PebbleDiagnostics.shared.record(
                .error,
                category: "timeline",
                message: "the Reminders app did not take \(reminder.title): \(String(reflecting: error))"
            )
        }
    }

    /// Takes these reminders out of the phone's Reminders app, if they were ever
    /// in it.
    func forgetInRemindersApp(_ identifiers: Set<UUID>) async {
        var mirrored = (try? await reminderStore.mirroredIdentifiers()) ?? [:]
        var changed = false
        for id in identifiers {
            guard let identifier = mirrored[id] else { continue }
            do {
                try await remindersAppStore.remove(identifier: identifier)
                mirrored[id] = nil
                changed = true
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "timeline",
                    message: "the Reminders app kept a reminder that is gone here: "
                        + String(reflecting: error)
                )
            }
        }
        guard changed else { return }
        try? await reminderStore.setMirroredIdentifiers(mirrored)
    }
}
