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
        try? await notificationPreferenceStore.save(notificationPreferences)
        notificationStatusMessage = enabled ? "Notifications enabled for this app." : "Notifications muted for this app."
    }

    public func setQuietHours(enabled: Bool, start: Int? = nil, end: Int? = nil) async {
        notificationPreferences.quietHoursEnabled = enabled
        if let start { notificationPreferences.quietHoursStart = min(23, max(0, start)) }
        if let end { notificationPreferences.quietHoursEnd = min(23, max(0, end)) }
        try? await notificationPreferenceStore.save(notificationPreferences)
    }

    public func sendTestNotification(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            notificationStatusMessage = "Connect a Pebble before sending a test notification."
            return
        }
        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: "Pebble Test",
            body: "Notifications are reaching your watch.",
            appName: "Pebble"
        )
        do {
            try await connection.client.sendNotification(notification)
            notificationStatusMessage = "Test notification sent."
            await record(notification, sentTo: [connection.device.name])
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
        var watchNames: [String] = []
        for connection in activeConnections {
            let client = connection.client
            do {
                try await retry(with: .watchWork) {
                    try await client.sendNotification(notification)
                }
                delivered.insert(connection.device.id)
                watchNames.append(connection.device.name)
            } catch {
                continue
            }
        }
        if !watchNames.isEmpty {
            await record(notification, sentTo: watchNames)
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

    func record(_ notification: PebbleTimelineNotification, sentTo watchNames: [String]) async {
        let sent = SentNotification(
            appName: notification.appName ?? "",
            title: notification.title,
            body: notification.body,
            sentAt: notification.timestamp,
            watchNames: watchNames
        )
        if let history = try? await sentNotificationStore.record(sent) {
            sentNotifications = history
        }
    }

    public func forgetSentNotifications() async {
        try? await sentNotificationStore.clear()
        sentNotifications = []
    }

    private func queue(_ notification: PendingDelivery<PebbleTimelineNotification>, reason: String) async {
        pendingNotifications.append(notification)
        if pendingNotifications.count > 20 {
            pendingNotifications.removeFirst(pendingNotifications.count - 20)
        }
        try? await pendingNotificationStore.save(pendingNotifications)
        await PebbleDiagnostics.shared.record(
            category: "notification",
            message: "Watch app notification queued: \(reason)"
        )
    }

    func handleCompanionFrame(
        _ frame: PebbleProtocolFrame,
        from connection: WatchConnection
    ) async {
        switch CompanionFrame(endpoint: frame.endpoint) {
        case .musicControl:
            musicCoordinator.handleFrame(frame)
        case .phoneControl:
            phoneCallCoordinator.handleFrame(frame)
        case .voiceControl:
            await connection.voiceCoordinator.handleVoiceFrame(frame)
        case .audioStream:
            await connection.voiceCoordinator.handleAudioFrame(frame)
        case .watchDatabaseWrite:
            await handleWatchDatabaseWrite(frame, on: connection)
        case nil:
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
            switch write.databaseID {
            case NotificationAppsCodec.databaseID:
                if let app = try? NotificationAppsCodec.decodeRecord(
                    key: write.key,
                    value: write.value,
                    timestamp: write.timestamp
                ),
                let apps = try? await notificationSourceAppStore.merge(app) {
                    notificationSourceApps = apps
                    connection.synchronizedNotificationAppRecords[app.bundleID] = NotificationAppsCodec.value(
                        for: (apps.first { $0.bundleID == app.bundleID } ?? app)
                            .asUnderstoodBy(connection.device)
                    )
                    succeeded = true
                    for other in activeConnections where other !== connection {
                        await synchronizeNotificationSourceApps(on: other)
                    }
                }
            case TimelinePinCodec.databaseID, TimelineReminderCodec.databaseID:
                if var item = try? PebbleTimelinePin(decoding: write.value) {
                    // Whatever the item's own flag says. It arrived on the
                    // endpoint the watch starts, so the watch already has it,
                    // and writing it back is never the right thing to do.
                    item.isFromWatch = true
                    await keep(item, from: connection)
                    succeeded = true
                }
            default:
                break
            }
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: succeeded))
        case .syncDone:
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: true))
        }
    }

    func synchronizeNotificationSourceApps(on connection: WatchConnection) async {
        for app in notificationSourceApps {
            // Cut down here rather than in the client, so that what is written
            // down as sent is the record that was sent.
            let record = app.asUnderstoodBy(connection.device)
            let value = NotificationAppsCodec.value(for: record)
            guard connection.synchronizedNotificationAppRecords[app.bundleID] != value else {
                continue
            }
            do {
                // Recorded as synchronized only once the watch says it took it, so a
                // refusal is retried on the next pass.
                try await connection.client.writeNotificationSourceApp(record)
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
        if let apps = try? await notificationSourceAppStore.update(app) {
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
        if let apps = try? await notificationSourceAppStore.update(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func setNotificationSourceAppVibePattern(
        bundleID: String,
        pattern: NotificationVibePattern?
    ) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.vibePattern = pattern
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppStore.update(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func setNotificationSourceAppFilterRules(
        bundleID: String,
        rules: [NotificationFilterRule]
    ) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.filterRules = rules
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppStore.update(app) {
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
        if let apps = try? await notificationSourceAppStore.update(app) {
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
        try? await notificationSourceAppStore.save(apps)
        notificationSourceApps = (try? await notificationSourceAppStore.apps()) ?? apps
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
            var watchNames: [String] = []
            for connection in activeConnections where next.isOwed(by: connection.device.id) {
                let client = connection.client
                do {
                    try await retry(with: .watchWork) {
                        try await client.sendNotification(next.work)
                    }
                    delivered.insert(connection.device.id)
                    watchNames.append(connection.device.name)
                } catch {
                    continue
                }
            }
            if !watchNames.isEmpty {
                await record(next.work, sentTo: watchNames)
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
        try? await pendingNotificationStore.save(pendingNotifications)
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
        if let saved = try? await pendingNotificationStore.notifications() {
            pendingNotifications = saved
        }
    }

    func sendOrQueueAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard let connection = activeConnections.first else {
            pendingAppMessages.append(StoredAppMessage(applicationID: applicationID, tuples: tuples))
            if pendingAppMessages.count > 50 { pendingAppMessages.removeFirst(pendingAppMessages.count - 50) }
            try await pendingAppMessageStore.save(pendingAppMessages)
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
        try? await pendingAppMessageStore.save(pendingAppMessages)
    }
}
