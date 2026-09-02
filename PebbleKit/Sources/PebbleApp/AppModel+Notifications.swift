public import PebbleProtocol
import Defaults
public import Foundation
import Retry
import SwiftUI

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
        let notification = PebbleTimelineNotification(
            parentApplicationID: application.id,
            title: normalizedTitle,
            body: normalizedBody,
            appName: application.displayName
        )
        guard !activeConnections.isEmpty else {
            await queue(PendingDelivery(work: notification), reason: "no watch is connected")
            return
        }
        var delivered: Set<String> = []
        for connection in activeConnections {
            let client = connection.client
            do {
                try await retry(with: .watchWork) {
                    try await client.sendNotification(notification)
                }
                delivered.insert(connection.device.id)
            } catch {
                continue
            }
        }
        guard activeConnections.allSatisfy({ delivered.contains($0.device.id) }) else {
            // The only caller is a `try?`-ed task in the companion runtime, which has
            // nowhere to put a throw. A watch that would not take it now is in the same
            // position as one that was not there at all — but the watches that did take
            // it are written down, so the flush does not show it to them twice.
            await queue(
                PendingDelivery(work: notification, deliveredTo: delivered),
                reason: "a watch would not take it"
            )
            return
        }
        await PebbleDiagnostics.shared.record(
            category: "notification",
            message: "Watch app notification sent"
        )
    }

    private func queue(_ notification: PendingDelivery<PebbleTimelineNotification>, reason: String) async {
        pendingNotifications.append(notification)
        if pendingNotifications.count > 20 {
            pendingNotifications.removeFirst(pendingNotifications.count - 20)
        }
        try? await pendingNotificationLibrary.save(pendingNotifications)
        await PebbleDiagnostics.shared.record(
            category: "notification",
            message: "Watch app notification queued: \(reason)"
        )
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
                connection.synchronizedNotificationAppRecords[app.bundleID] = NotificationAppsCodec.value(
                    for: apps.first { $0.bundleID == app.bundleID } ?? app
                )
                succeeded = true
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
                // Recorded as synchronized only once the watch says it took it, so a
                // refusal is retried on the next pass.
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

    public func setNotificationSourceAppIcon(bundleID: String, icon: PebbleTimelineIcon?) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.icon = icon
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppLibrary.update(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func setNotificationSourceAppColors(
        bundleID: String,
        background: PebbleColor?,
        foreground: PebbleColor?
    ) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.backgroundColor = background
        app.foregroundColor = foreground
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppLibrary.update(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func setNotificationSourceAppMute(bundleID: String, muteState: NotificationAppMuteState) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.muteState = muteState
        app.muteExpiration = nil
        app.stateUpdated = .now
        // `merge` is for records the watch sends, and its timestamp gate can
        // discard a change made in the same second.
        if let apps = try? await notificationSourceAppLibrary.update(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    // Named rather than numbered: the list they were picked from may have been
    // narrowed by a search.
    public func removeNotificationSourceApps(_ removed: [NotificationSourceApp]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.bundleID))
        let apps = notificationSourceApps.filter { !identifiers.contains($0.bundleID) }
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
        if let flush = pendingNotificationFlush {
            await flush.value
            return
        }
        let flush = Task { await self.deliverPendingNotifications() }
        pendingNotificationFlush = flush
        await flush.value
        pendingNotificationFlush = nil
    }

    private func deliverPendingNotifications() async {
        while let next = pendingNotifications.first(where: { queued in
            activeConnections.contains { queued.isOwed(by: $0.device.id) }
        }) {
            var delivered = next.deliveredTo
            for connection in activeConnections where next.isOwed(by: connection.device.id) {
                let client = connection.client
                do {
                    try await retry(with: .watchWork) {
                        try await client.sendNotification(next.work)
                    }
                    delivered.insert(connection.device.id)
                } catch {
                    continue
                }
            }
            // Found again by identity: sending suspends, so the queue need not
            // still hold this one where it did.
            guard let index = pendingNotifications.firstIndex(where: { $0.work.id == next.work.id }) else {
                continue
            }
            guard delivered != pendingNotifications[index].deliveredTo else {
                // Nothing got through. Another pass would ask the same watches
                // the same question.
                break
            }
            pendingNotifications[index].deliveredTo = delivered
            if watchesOwed(pendingNotifications[index].deliveredTo).isEmpty {
                pendingNotifications.remove(at: index)
            }
        }
        try? await pendingNotificationLibrary.save(pendingNotifications)
        if pendingNotifications.isEmpty {
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Queued watch app notifications delivered"
            )
        }
    }

    /// Which watches have still not had a piece of queued work: every watch the
    /// app knows of, so an entry is finished only once nobody is waiting for it.
    private func watchesOwed(_ deliveredTo: Set<String>) -> Set<String> {
        let known = Set(savedWatches.map(\.id)).union(connections.map(\.device.id))
        return known.subtracting(deliveredTo)
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
        if let flush = pendingAppMessageFlush {
            await flush.value
            return
        }
        let flush = Task { await self.deliverPendingAppMessages() }
        pendingAppMessageFlush = flush
        await flush.value
        pendingAppMessageFlush = nil
    }

    private func deliverPendingAppMessages() async {
        while let connection = activeConnections.first, let message = pendingAppMessages.first {
            do {
                try await connection.client.sendAppMessage(
                    applicationID: message.applicationID,
                    tuples: message.tuples
                )
            } catch { break }
            // Removed by identity: sending suspends, so the message at the front
            // afterwards need not be the one just sent.
            pendingAppMessages.removeAll { $0.id == message.id }
        }
        try? await pendingAppMessageLibrary.save(pendingAppMessages)
    }
}
