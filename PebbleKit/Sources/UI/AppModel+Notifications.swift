import Algorithms
public import API
import Defaults
public import Foundation
import Retry
import SwiftUI

/// Notifications sent to a watch, and messages coming back.
extension AppModel {
    public func setCompanionNotificationsEnabled(_ enabled: Bool) {
        companionNotificationsEnabled = enabled
        Defaults[.companionNotificationsEnabled] = enabled
        notificationStatusMessage = enabled
            ? "Watch app notifications are enabled."
            : "Watch app notifications are disabled."
    }

    public func setNotificationsEnabled(_ enabled: Bool, applicationID: UUID) async {
        if enabled { notificationPreferences.mutedApplicationIDs.remove(applicationID) }
        else { notificationPreferences.mutedApplicationIDs.insert(applicationID) }
        try? await notificationPreferenceLibrary.save(notificationPreferences)
        notificationStatusMessage = enabled ? "Notifications enabled for this app." : "Notifications muted for this app."
    }

    public func setQuietHours(enabled: Bool, start: Int? = nil, end: Int? = nil) async {
        notificationPreferences.quietHoursEnabled = enabled
        if let start { notificationPreferences.quietHoursStart = min(23, max(0, start)) }
        if let end { notificationPreferences.quietHoursEnd = min(23, max(0, end)) }
        try? await notificationPreferenceLibrary.save(notificationPreferences)
    }

    public func sendTestNotification(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            notificationStatusMessage = "Connect a Pebble before sending a test notification."
            return
        }
        do {
            try await connection.client.sendNotification(PebbleTimelineNotification(
                parentApplicationID: UUID(),
                title: "Pebble Test",
                body: "Notifications are reaching your watch.",
                appName: "Pebble"
            ))
            notificationStatusMessage = "Test notification sent."
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Test notification sent"
            )
        } catch {
            notificationStatusMessage = "The test notification could not be sent."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "notification",
                message: "Test notification delivery failed"
            )
        }
    }

    /// Sends a frame to every connected watch, throwing only when no watch
    /// received it.
    func broadcast(_ frame: PebbleProtocolFrame) async throws {
        var delivered = false
        for connection in activeConnections {
            do {
                try await connection.client.send(frame)
                delivered = true
            } catch {
                continue
            }
        }
        guard delivered else {
            throw PebbleConnectionError.disconnected
        }
    }

    func sendCompanionNotification(
        application: PebbleApplication,
        title: String,
        body: String
    ) async throws {
        guard companionNotificationsEnabled else { return }
        guard notificationPreferences.permits(applicationID: application.id, at: Date()) else {
            await PebbleDiagnostics.shared.record(category: "notification", message: "Notification suppressed by delivery preferences")
            return
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty || !normalizedBody.isEmpty else { return }
        let now = Date()
        recentNotificationFingerprints = recentNotificationFingerprints.filter {
            now.timeIntervalSince($0.value) < 30
        }
        let fingerprint = "\(application.id.uuidString)|\(normalizedTitle)|\(normalizedBody)"
        guard recentNotificationFingerprints[fingerprint] == nil else { return }
        recentNotificationFingerprints[fingerprint] = now
        do {
            let notification = PebbleTimelineNotification(
                parentApplicationID: application.id,
                title: normalizedTitle,
                body: normalizedBody,
                appName: application.displayName
            )
            guard !activeConnections.isEmpty else {
                pendingNotifications.append(notification)
                if pendingNotifications.count > 20 {
                    pendingNotifications.removeFirst(pendingNotifications.count - 20)
                }
                try? await pendingNotificationLibrary.save(pendingNotifications)
                await PebbleDiagnostics.shared.record(
                    category: "notification",
                    message: "Watch app notification queued until reconnection"
                )
                return
            }
            for connection in activeConnections {
                let client = connection.client
                try await retry(with: .watchWork) {
                    try await client.sendNotification(notification)
                }
            }
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Watch app notification sent"
            )
        } catch {
            recentNotificationFingerprints[fingerprint] = nil
            throw error
        }
    }

    func handleCompanionFrame(
        _ frame: PebbleProtocolFrame,
        from connection: WatchConnection
    ) async {
        switch frame.endpoint {
        case MusicControlCodec.endpoint:
            musicCoordinator.handleFrame(frame)
        case PhoneControlCodec.endpoint:
            phoneCallCoordinator.handleFrame(frame)
        case VoiceControlCodec.endpoint:
            await connection.voiceCoordinator.handleVoiceFrame(frame)
        case AudioStreamCodec.endpoint:
            await connection.voiceCoordinator.handleAudioFrame(frame)
        case BlobDB2Codec.endpoint:
            await handleWatchDatabaseWrite(frame, on: connection)
        default:
            return
        }
    }

    func handleWatchDatabaseWrite(
        _ frame: PebbleProtocolFrame,
        on connection: WatchConnection
    ) async {
        guard let message = try? BlobDB2Codec.decode(frame) else {
            return
        }
        switch message {
        case .write(let write), .writeBack(let write):
            var succeeded = false
            if write.databaseID == NotificationAppsCodec.databaseID,
               let app = try? NotificationAppsCodec.decodeRecord(
                   key: write.key,
                   value: write.value,
                   timestamp: write.timestamp
               ),
               let apps = try? await notificationSourceAppLibrary.merge(app) {
                notificationSourceApps = apps
                // The watch already holds this record; skip echoing it back.
                connection.synchronizedNotificationAppRecords[app.bundleID] = NotificationAppsCodec.value(
                    for: apps.first { $0.bundleID == app.bundleID } ?? app
                )
                succeeded = true
                // Other connected watches still need the updated record.
                for other in activeConnections where other !== connection {
                    await synchronizeNotificationSourceApps(on: other)
                }
            }
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: succeeded))
        case .syncDone:
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: true))
        }
    }

    func synchronizeNotificationSourceApps(on connection: WatchConnection) async {
        for app in notificationSourceApps {
            let value = NotificationAppsCodec.value(for: app)
            guard connection.synchronizedNotificationAppRecords[app.bundleID] != value else {
                continue
            }
            do {
                // Awaited rather than posted and forgotten: the record is only
                // recorded as synchronized once the watch says it took it, so
                // a refusal is retried on the next pass instead of being
                // remembered as done.
                try await connection.client.writeNotificationSourceApp(app)
                connection.synchronizedNotificationAppRecords[app.bundleID] = value
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "notification",
                    message: "\(connection.device.name) rejected the setting for \(app.displayName): "
                        + String(reflecting: error)
                )
                return
            }
        }
    }

    public func setNotificationSourceAppMute(bundleID: String, muteState: NotificationAppMuteState) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.muteState = muteState
        app.muteExpiration = nil
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppLibrary.merge(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func removeNotificationSourceApps(at offsets: IndexSet) async {
        let removed = offsets.compactMap { notificationSourceApps.indices.contains($0) ? notificationSourceApps[$0] : nil }
        guard !removed.isEmpty else { return }
        var apps = notificationSourceApps
        apps.remove(atOffsets: offsets)
        try? await notificationSourceAppLibrary.save(apps)
        notificationSourceApps = (try? await notificationSourceAppLibrary.apps()) ?? apps
        for app in removed {
            for connection in activeConnections {
                connection.synchronizedNotificationAppRecords[app.bundleID] = nil
                do {
                    try await connection.client.removeNotificationSourceApp(bundleID: app.bundleID)
                } catch {
                    await PebbleDiagnostics.shared.record(
                        .error,
                        category: "notification",
                        message: "\(connection.device.name) kept \(app.displayName): "
                            + String(reflecting: error)
                    )
                }
            }
        }
    }

    func handleAppMessage(_ message: AppMessageData, from connection: WatchConnection) async {
        do {
            guard let application = (watchApplications + watchfaces).first(where: {
                $0.id == message.applicationID
            }), let source = try await applicationLibrary.companionJavaScript(
                applicationID: application.id
            ) else {
                try await connection.client.respondToAppMessage(
                    transactionID: message.transactionID,
                    acknowledged: false
                )
                return
            }
            try await companionRuntime.load(source: source, application: application)
            try await companionRuntime.deliver(message)
            try await connection.client.respondToAppMessage(
                transactionID: message.transactionID,
                acknowledged: true
            )
        } catch {
            try? await connection.client.respondToAppMessage(
                transactionID: message.transactionID,
                acknowledged: false
            )
            await PebbleDiagnostics.shared.record(
                .error,
                category: "appmessage",
                message: "Incoming AppMessage delivery failed"
            )
        }
    }

    func flushPendingNotifications() async {
        guard !activeConnections.isEmpty, !pendingNotifications.isEmpty else { return }
        var remaining: [PebbleTimelineNotification] = []
        for (index, notification) in pendingNotifications.indexed() {
            do {
                for connection in activeConnections {
                    let client = connection.client
                    try await retry(with: .watchWork) {
                        try await client.sendNotification(notification)
                    }
                }
            } catch {
                remaining.append(contentsOf: pendingNotifications[index...])
                break
            }
        }
        pendingNotifications = remaining
        try? await pendingNotificationLibrary.save(remaining)
        if remaining.isEmpty {
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Queued watch app notifications delivered"
            )
        }
    }

    func restorePendingNotifications() async {
        if let saved = try? await pendingNotificationLibrary.notifications() {
            pendingNotifications = saved
        }
    }

    func sendOrQueueAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard let connection = activeConnections.first else {
            pendingAppMessages.append(StoredAppMessage(applicationID: applicationID, tuples: tuples))
            if pendingAppMessages.count > 50 { pendingAppMessages.removeFirst(pendingAppMessages.count - 50) }
            try await pendingAppMessageLibrary.save(pendingAppMessages)
            return
        }
        try await connection.client.sendAppMessage(applicationID: applicationID, tuples: tuples)
    }

    func flushPendingAppMessages() async {
        guard let connection = activeConnections.first else { return }
        while let message = pendingAppMessages.first {
            do {
                try await connection.client.sendAppMessage(
                    applicationID: message.applicationID,
                    tuples: message.tuples
                )
                pendingAppMessages.removeFirst()
            } catch { break }
        }
        try? await pendingAppMessageLibrary.save(pendingAppMessages)
    }
}
