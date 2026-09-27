public import PebbleProtocol
import Defaults
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func setCompanionNotificationsEnabled(_ enabled: Bool) {
        notifications.companionEnabled = enabled
        Defaults[.companionNotificationsEnabled] = enabled
        notifications.settingsFeedback = .success(
            enabled
                ? "Watch app notifications are enabled."
                : "Watch app notifications are disabled."
        )
    }

    public func setNotificationsEnabled(_ enabled: Bool, applicationID: UUID) async {
        if enabled { notifications.preferences.mutedApplicationIDs.remove(applicationID) }
        else { notifications.preferences.mutedApplicationIDs.insert(applicationID) }
        await savePreferences(
            saying: .success(enabled ? "Notifications enabled for this app." : "Notifications muted for this app.")
        )
    }

    public func setQuietHours(enabled: Bool, start: Int? = nil, end: Int? = nil) async {
        notifications.preferences.areQuietHoursEnabled = enabled
        if let start { notifications.preferences.quietHoursStart = min(23, max(0, start)) }
        if let end { notifications.preferences.quietHoursEnd = min(23, max(0, end)) }
        await savePreferences(saying: .success("Quiet hours updated."))
    }

    /// Writes the preferences down and answers for the write, not for the
    /// intention.
    ///
    /// The change is kept when the write fails, because it is already in force:
    /// what the app does with the next notification is read from
    /// `notifications.preferences`, not from the file. Undoing it would take
    /// away something that is working. What cannot be promised is that it
    /// survives a restart, and that is what the failure says.
    private func savePreferences(saying success: FeatureFeedback) async {
        do {
            try await notificationPreferenceStore.save(notifications.preferences)
            notifications.settingsFeedback = success
        } catch {
            notifications.settingsFeedback = .failure(
                "This change could not be saved. It works now, but the app will forget it when it next starts."
            )
            await DiagnosticLog.shared.record(
                .error,
                category: "notification",
                message: "the notification preferences could not be saved: \(String(reflecting: error))"
            )
        }
    }

    public func sendTestNotification(watchID: WatchID) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            diagnostics[watchID].feedback[.testNotification] = .failure(
                "Connect a Pebble before sending a test notification."
            )
            return
        }
        let notification = TimelineNotification(
            parentApplicationID: UUID(),
            title: String(localized: "Pebble Test", bundle: .module),
            body: String(localized: "Notifications are reaching your watch.", bundle: .module),
            appName: "Pebble"
        )
        let client = connection.client
        do {
            try await retry(with: .watchWork) { try await client.write(.notification(notification)) }
            diagnostics[watchID].feedback[.testNotification] = .success("Test notification sent.")
            await record(notification, sentTo: [connection.watch.name])
            await DiagnosticLog.shared.record(
                category: "notification",
                message: "Test notification sent"
            )
        } catch {
            diagnostics[watchID].feedback[.testNotification] = .failure("The test notification could not be sent.")
            await DiagnosticLog.shared.record(
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
            throw WatchConnectionError.disconnected
        }
    }

    func sendCompanionNotification(
        application: WatchApplication,
        title: String,
        body: String
    ) async {
        guard notifications.companionEnabled else { return }
        guard notifications.preferences.permits(applicationID: application.id, at: Date()) else {
            await DiagnosticLog.shared.record(category: "notification", message: "Notification suppressed by delivery preferences")
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
        let notification = TimelineNotification(
            parentApplicationID: application.id,
            title: normalizedTitle,
            body: normalizedBody,
            appName: application.displayName
        )
        guard !activeConnections.isEmpty else {
            await queue(PendingDelivery(work: notification), reason: "no watch is connected")
            return
        }
        var delivered: Set<WatchID> = []
        var watchNames: [String] = []
        for connection in activeConnections {
            let client = connection.client
            do {
                try await retry(with: .watchWork) {
                    try await client.write(.notification(notification))
                }
                delivered.insert(connection.watch.id)
                watchNames.append(connection.watch.name)
            } catch {
                continue
            }
        }
        if !watchNames.isEmpty {
            await record(notification, sentTo: watchNames)
        }
        // Owed to every watch the app knows, connected or not — the same rule
        // the queue flushes by, so whether a watch that is away gets it does
        // not depend on whether another happened to be connected.
        guard watchesOwed(delivered).isEmpty else {
            // The script's call takes no callback, so the queue is the only
            // answer. The watches that did take it are written down, so the
            // flush does not show it to them twice.
            await queue(
                PendingDelivery(work: notification, deliveredTo: delivered),
                reason: "a watch has not had it yet"
            )
            return
        }
        await DiagnosticLog.shared.record(
            category: "notification",
            message: "Watch app notification sent"
        )
    }

    func record(_ notification: TimelineNotification, sentTo watchNames: [String]) async {
        let sent = SentNotification(
            appName: notification.appName ?? "",
            title: notification.title,
            body: notification.body,
            sentAt: notification.timestamp,
            watchNames: watchNames
        )
        do {
            notifications.sent = try await sentNotificationStore.record(sent)
        } catch {
            await DiagnosticLog.shared.record(
                .error,
                category: "notification",
                message: "the notification history could not be saved: \(String(reflecting: error))"
            )
        }
    }

    /// The queue on disk is what a relaunch delivers from: one that did not
    /// save loses a notification, or sends one twice, and says so here.
    private func savePendingNotifications() async {
        do {
            try await pendingNotificationStore.save(pendingNotifications)
        } catch {
            await DiagnosticLog.shared.record(
                .error,
                category: "notification",
                message: "the notification queue could not be saved: \(String(reflecting: error))"
            )
        }
    }

    /// Empties the list of what was sent, on screen and on disk.
    ///
    /// The screen is only emptied once the file is, unlike the preferences
    /// above: "cleared" is a claim about what is stored, so showing an empty
    /// list over a file that still holds everything is simply false — and the
    /// entries come back at the next launch to prove it.
    public func forgetSentNotifications() async {
        do {
            try await sentNotificationStore.clear()
            notifications.sent = []
            notifications.historyFeedback = nil
        } catch {
            notifications.historyFeedback = .failure("The history could not be cleared.")
            await DiagnosticLog.shared.record(
                .error,
                category: "notification",
                message: "the sent-notification history could not be cleared: \(String(reflecting: error))"
            )
        }
    }

    private func queue(_ notification: PendingDelivery<TimelineNotification>, reason: String) async {
        pendingNotifications.append(notification)
        if pendingNotifications.count > 20 {
            pendingNotifications.removeFirst(pendingNotifications.count - 20)
        }
        await savePendingNotifications()
        await DiagnosticLog.shared.record(
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
            // Calls are left to ANCS, which gives the watch the caller's name;
            // telling it over Pebble Protocol as well raced that and lost it,
            // and iOS lets no app answer or end a carrier call (#80). With no
            // call sent from here, the watch has nothing of ours to act on.
            return
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
                    notifications.sourceApps = apps
                    connection.synchronizedNotificationAppRecords[app.bundleID] = NotificationAppsCodec.value(
                        for: (apps.first { $0.bundleID == app.bundleID } ?? app)
                            .asUnderstoodBy(connection.watch)
                    )
                    succeeded = true
                    relayToOtherWatches(from: connection) { other in
                        await self.synchronizeNotificationSourceApps(on: other)
                    }
                }
            case WatchSettingsCodec.databaseID:
                if let (setting, rawValue) = WatchSettingsCodec.decodeRecord(
                    key: write.key,
                    value: write.value
                ) {
                    succeeded = applyWatchSetting(setting, rawValue: rawValue, from: connection)
                } else if let (button, assignment) = WatchSettingsCodec.decodeQuickLaunch(
                    key: write.key,
                    value: write.value
                ) {
                    // A button held down on the wrist to assign whatever was
                    // running.
                    succeeded = applyQuickLaunch(button, assignment: assignment, from: connection)
                } else {
                    // A key this app has no switch for, which is most of the
                    // firmware's seventy-odd syncable settings. Taken rather
                    // than refused: the phone has nowhere to put it and cannot
                    // acquire one by saying no, and what a refused sync record
                    // makes the watch do next was not measured. Said out loud
                    // so it is not simply swallowed.
                    succeeded = true
                    await DiagnosticLog.shared.record(
                        category: "settings",
                        message: "\(connection.watch.name) synced a setting this app does not have: "
                            + String(decoding: write.key.prefix { $0 != 0 }, as: UTF8.self)
                    )
                }
            case TimelinePinCodec.databaseID, TimelineReminderCodec.databaseID:
                if var item = try? TimelinePin(decoding: write.value) {
                    // Whatever the item's own flag says. It arrived on the
                    // endpoint the watch starts, so the watch already has it,
                    // and writing it back is never the right thing to do.
                    item.isFromWatch = true
                    await storeItemMadeOnWatch(item, from: connection)
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

    /// Passes on to every other watch what one watch wrote to its own
    /// database, once the caller has answered it.
    ///
    /// Not awaited before the answer. The watch sends the record again after
    /// thirty seconds without one (`SYNC_TIMEOUT_SECONDS`,
    /// `services/blob_db/sync.c`), and a write to another watch may take twenty
    /// of those — all of them, for a watch that has just gone out of range. Nor
    /// awaited by the caller at all: the frame loop the record came in on would
    /// be held as long, and the next record the watch has queued behind this
    /// one answered no sooner.
    func relayToOtherWatches(
        from source: WatchConnection,
        _ relay: @escaping @MainActor (WatchConnection) async -> Void
    ) {
        let previous = watchDatabaseRelay
        watchDatabaseRelay = Task {
            await previous?.value
            for other in activeConnections where other !== source {
                await relay(other)
            }
        }
    }

    /// Keeps a change to one of the phone's apps and tells every watch.
    ///
    /// The five setters above each ended in this, and each ended it silently:
    /// a store that refused the change was swallowed by a `try?`, and nothing
    /// was said either way. One place to answer from, on the screens where
    /// those changes are made.
    private func saveAndDistribute(_ app: NotificationSourceApp) async {
        guard let apps = try? await notificationSourceAppStore.update(app) else {
            notifications.sourceAppFeedback = .failure("The change could not be saved.")
            return
        }
        notifications.sourceApps = apps
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
        notifications.sourceAppFeedback = .success("Saved. A Pebble that is not connected is told when it connects.")
    }

    func synchronizeNotificationSourceApps(on connection: WatchConnection) async {
        let watchID = connection.watch.id
        let client = connection.client
        // Forgotten here while this watch was away: nothing else will name them.
        let kept = Set(notifications.sourceApps.map(\.bundleID))
        for bundleID in await writtenKeys(.notificationSourceApp, on: watchID) where !kept.contains(bundleID) {
            do {
                try await removeRecord(.notificationSourceApp(bundleID: bundleID), from: client)
                await noteRemoved(bundleID, .notificationSourceApp, on: watchID)
            } catch {
                await DiagnosticLog.shared.record(
                    .error,
                    category: "notification",
                    message: "\(connection.watch.name) kept an app forgotten here: " + String(reflecting: error)
                )
                break
            }
        }
        for app in notifications.sourceApps {
            // Cut down here rather than in the client, so that what is written
            // down as sent is the record that was sent.
            let record = app.asUnderstoodBy(connection.watch)
            let value = NotificationAppsCodec.value(for: record)
            guard connection.synchronizedNotificationAppRecords[app.bundleID] != value else {
                continue
            }
            do {
                // Recorded as synchronized only once the watch says it took it, so a
                // refusal is retried on the next pass.
                try await retry(with: .watchWork) { try await client.write(.notificationSourceApp(record)) }
                connection.synchronizedNotificationAppRecords[app.bundleID] = value
                await noteWritten(app.bundleID, .notificationSourceApp, on: watchID)
            } catch {
                await DiagnosticLog.shared.record(
                    .error,
                    category: "notification",
                    message: "\(connection.watch.name) rejected the setting for \(app.displayName): "
                        + String(reflecting: error)
                )
                return
            }
        }
    }

    public func setNotificationSourceAppIcon(bundleID: String, icon: TimelineIcon?) async {
        guard var app = notifications.sourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.icon = icon
        app.stateUpdated = .now
        await saveAndDistribute(app)
    }

    public func setNotificationSourceAppColors(
        bundleID: String,
        background: PebbleColor?,
        foreground: PebbleColor?
    ) async {
        guard var app = notifications.sourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.backgroundColor = background
        app.foregroundColor = foreground
        app.stateUpdated = .now
        await saveAndDistribute(app)
    }

    public func setNotificationSourceAppVibePattern(
        bundleID: String,
        pattern: NotificationVibePattern?
    ) async {
        guard var app = notifications.sourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.vibePattern = pattern
        app.stateUpdated = .now
        await saveAndDistribute(app)
    }

    public func setNotificationSourceAppFilterRules(
        bundleID: String,
        rules: [NotificationFilterRule]
    ) async {
        guard var app = notifications.sourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.filterRules = rules
        app.stateUpdated = .now
        await saveAndDistribute(app)
    }

    public func setNotificationSourceAppMute(bundleID: String, muteState: NotificationAppMuteState) async {
        guard var app = notifications.sourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.muteState = muteState
        app.muteExpiration = nil
        app.stateUpdated = .now
        // `merge` is for records the watch sends, and its timestamp gate can
        // discard a change made in the same second.
        await saveAndDistribute(app)
    }

    // Named rather than numbered: the list they were picked from may have been
    // narrowed by a search.
    public func removeNotificationSourceApps(_ removed: [NotificationSourceApp]) async {
        guard !removed.isEmpty else { return }
        let identifiers = Set(removed.map(\.bundleID))
        let apps = notifications.sourceApps.filter { !identifiers.contains($0.bundleID) }
        do {
            try await notificationSourceAppStore.save(apps)
        } catch {
            notifications.sourceAppFeedback = .failure("The change could not be saved.")
            return
        }
        notifications.sourceApps = apps
        for app in removed {
            for connection in activeConnections {
                connection.synchronizedNotificationAppRecords[app.bundleID] = nil
                do {
                    try await removeRecord(.notificationSourceApp(bundleID: app.bundleID), from: connection.client)
                    await noteRemoved(app.bundleID, .notificationSourceApp, on: connection.watch.id)
                } catch {
                    await DiagnosticLog.shared.record(
                        .error,
                        category: "notification",
                        message: "\(connection.watch.name) kept \(app.displayName): "
                            + String(reflecting: error)
                    )
                }
            }
        }
        // Said by count rather than by name: this takes a swipe on one row and
        // an edit-mode sweep over several, and the list is what is left.
        notifications.sourceAppFeedback = .success("Forgot \(removed.count) apps.")
    }

    func handleAppMessage(_ message: AppMessageData, from connection: WatchConnection) async {
        do {
            guard let application = applications.all.first(where: {
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
            companionRuntimeWatchID = connection.watch.id
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
            await DiagnosticLog.shared.record(
                .error,
                category: "appmessage",
                message: "Incoming AppMessage delivery failed"
            )
        }
    }

    func flushPendingNotifications() async {
        // Waited out, then run again rather than joined: a joiner can arrive
        // in the hop between the running flush's last delivery and the handle
        // being cleared, and what it queued would then wait for the next
        // trigger. The extra pass finds an empty queue when the earlier flush
        // covered it, which costs no sends.
        while let flush = pendingNotificationFlush {
            await flush.value
        }
        // The task clears its own handle before finishing. Cleared by the
        // caller instead, a second waiter could wake first, find the handle
        // still pointing at the finished task, and spin: awaiting a finished
        // task need not suspend, so the loop above would never yield the main
        // actor back to the caller that was going to clear it.
        let flush = Task {
            await self.deliverPendingNotifications()
            self.pendingNotificationFlush = nil
        }
        pendingNotificationFlush = flush
        await flush.value
    }

    /// A watch that refuses one entry is not asked again this pass, and the
    /// others go on: stopping at the first refusal left the entries owed only
    /// to another watch unsent while it sat there connected.
    private func deliverPendingNotifications() async {
        var attempted: Set<UUID> = []
        var refusing: Set<WatchID> = []
        func willing(_ queued: PendingDelivery<TimelineNotification>) -> [WatchConnection] {
            activeConnections.filter { queued.isOwed(by: $0.watch.id) && !refusing.contains($0.watch.id) }
        }
        while let next = pendingNotifications.first(where: { queued in
            !attempted.contains(queued.work.id) && !willing(queued).isEmpty
        }) {
            attempted.insert(next.work.id)
            var delivered = next.deliveredTo
            var watchNames: [String] = []
            for connection in willing(next) {
                let client = connection.client
                do {
                    try await retry(with: .watchWork) {
                        try await client.write(.notification(next.work))
                    }
                    delivered.insert(connection.watch.id)
                    watchNames.append(connection.watch.name)
                } catch {
                    refusing.insert(connection.watch.id)
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
            guard delivered != pendingNotifications[index].deliveredTo else { continue }
            pendingNotifications[index].deliveredTo = delivered
            if watchesOwed(pendingNotifications[index].deliveredTo).isEmpty {
                pendingNotifications.remove(at: index)
            }
        }
        await savePendingNotifications()
        if pendingNotifications.isEmpty {
            await DiagnosticLog.shared.record(
                category: "notification",
                message: "Queued watch app notifications delivered"
            )
        }
    }

    /// Which watches have still not had a piece of queued work: every watch the
    /// app knows of, so an entry is finished only once nobody is waiting for it.
    private func watchesOwed(_ deliveredTo: Set<WatchID>) -> Set<WatchID> {
        let known = Set(watches.saved.map(\.id)).union(connections.map(\.watch.id))
        return known.subtracting(deliveredTo)
    }

    func restorePendingNotifications() async {
        if let saved = try? await pendingNotificationStore.notifications() {
            pendingNotifications = saved
        }
    }

    /// The connection the companion script's watch is on, else the first.
    var companionRuntimeConnection: WatchConnection? {
        activeConnections.first { $0.watch.id == companionRuntimeWatchID } ?? activeConnections.first
    }

    /// Throws whenever the message did not reach the watch, including when it
    /// was queued for the next connection: the script is told it failed, which
    /// is what happened. Not retried — a refusal means the app is not running,
    /// and it is the same refusal a moment later.
    func sendOrQueueAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        let destination = companionRuntimeWatchID
        let message = StoredAppMessage(applicationID: applicationID, tuples: tuples, watchID: destination)
        guard let connection = activeConnections.first(where: { destination == nil || $0.watch.id == destination }) else {
            try await queue(message)
            throw WatchConnectionError.disconnected
        }
        do {
            try await connection.client.sendAppMessage(applicationID: applicationID, tuples: tuples)
        } catch let error as WatchConnectionError where !error.isWorthAnotherAttempt {
            // The link went with the message on it: the transport kept no copy,
            // so this is the only one.
            try await queue(message)
            throw error
        }
    }

    private func queue(_ message: StoredAppMessage) async throws {
        pendingAppMessages.append(message)
        if pendingAppMessages.count > 50 { pendingAppMessages.removeFirst(pendingAppMessages.count - 50) }
        try await pendingAppMessageStore.save(pendingAppMessages)
    }

    /// How long a queued message is worth delivering. A settings change made a
    /// day ago is one the reader has likely made again since.
    static var appMessageLifetime: TimeInterval { 24 * 60 * 60 }

    func flushPendingAppMessages() async {
        // The same wait-then-run as the notification flush, for the same hop —
        // including the task clearing its own handle, for the same spin.
        while let flush = pendingAppMessageFlush {
            await flush.value
        }
        let flush = Task {
            await self.deliverPendingAppMessages()
            self.pendingAppMessageFlush = nil
        }
        pendingAppMessageFlush = flush
        await flush.value
    }

    /// A refusal holds back only the messages for that app on that watch: the
    /// watch refuses anything for an app that is not running
    /// (`app_message_inbox.c`), and one refused message at the front used to
    /// keep every other app's waiting behind it for good.
    private func deliverPendingAppMessages() async {
        let now = Date()
        pendingAppMessages.removeAll { now.timeIntervalSince($0.createdAt) > Self.appMessageLifetime }
        var attempted: Set<UUID> = []
        var refused: Set<String> = []
        var unreachable: Set<WatchID> = []
        while let message = pendingAppMessages.first(where: { !attempted.contains($0.id) }) {
            attempted.insert(message.id)
            guard let connection = activeConnections.first(where: { connection in
                !unreachable.contains(connection.watch.id)
                    && (message.watchID == nil || message.watchID == connection.watch.id)
            }) else { continue }
            // Kept in order behind a refused one for the same app.
            let key = "\(connection.watch.id.rawValue)|\(message.applicationID)"
            guard !refused.contains(key) else { continue }
            do {
                try await connection.client.sendAppMessage(
                    applicationID: message.applicationID,
                    tuples: message.tuples
                )
            } catch AppMessageClientError.negativeAcknowledgement {
                refused.insert(key)
                continue
            } catch {
                unreachable.insert(connection.watch.id)
                continue
            }
            // Removed by identity: sending suspends, so the message at the front
            // afterwards need not be the one just sent.
            pendingAppMessages.removeAll { $0.id == message.id }
        }
        try? await pendingAppMessageStore.save(pendingAppMessages)
    }
}
