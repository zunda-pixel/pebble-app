#if os(iOS)
public import AccessoryNotifications
public import AccessoryTransportExtension
import Foundation
import OSLog
import PebbleProtocol
import Synchronization

/// The AccessoryDataProvider's part: each notification iOS forwards is written
/// in the form the watch parses, and each action the watch sends back is
/// answered to iOS as the response to that notification.
public final class NotificationForwardingHandler: NotificationsForwarding.AccessoryNotificationsHandler {
    private struct State {
        var session: NotificationsForwarding.Session?
        var sources = ReplySources()
    }

    private let state = Mutex(State())

    public init() {}

    public func didActivate(for session: NotificationsForwarding.Session) {
        state.withLock { $0.session = session }
    }

    public func didInvalidate() {
        state.withLock { $0.session = nil }
    }

    public func addNotification(
        _ notification: AccessoryNotification,
        alertingContext: AlertingContext
    ) async throws -> Bool {
        remember(notification)
        do {
            try await send(.present(ForwardedNotification(notification, shouldAlert: alertingContext.shouldAlert)))
            return true
        } catch {
            forwardingLog.error("a notification was not forwarded: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func updateNotification(_ notification: AccessoryNotification) {
        remember(notification)
        let forwarded = ForwardedNotification(notification, shouldAlert: false)
        Task { try? await send(.present(forwarded)) }
    }

    public func removeNotification(identifier: AccessoryNotification.Identifier) {
        let notificationIdentifier = identifier.notificationIdentifier
        state.withLock { $0.sources.forget(notificationIdentifier) }
        Task { try? await send(.remove(identifier: notificationIdentifier)) }
    }

    public func removeAllNotifications() {
        state.withLock { $0.sources.forgetAll() }
        Task { try? await send(.removeAll) }
    }

    public func messageHandler(_ message: TransportMessage) {
        let reply: AccessoryNotificationReply
        do {
            reply = try AccessoryNotificationCodec.decodeReply([UInt8](message.data))
        } catch {
            forwardingLog.error("the watch sent a reply that could not be read")
            return
        }
        let (session, notification) = state.withLock {
            ($0.session, $0.sources.notification(onTheWatchAs: reply.notificationIdentifier))
        }
        guard let session, let notification else {
            // The watch has already said "Sent"; iOS has no response to match a
            // notification it no longer lists, or one from before a session.
            forwardingLog.error("a reply named a notification that is no longer forwarded")
            return
        }
        let response = NotificationResponse(
            sourceIdentifier: notification.sourceIdentifier,
            notificationIdentifier: notification.notificationIdentifier,
            actionIdentifier: reply.actionIdentifier,
            userText: reply.text
        )
        Task {
            do {
                try await session.sendResponse(response)
            } catch {
                forwardingLog.error("iOS refused the watch's reply: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func remember(_ notification: AccessoryNotification) {
        state.withLock { $0.sources.remember(notification.identifier) }
    }

    private func send(_ message: AccessoryNotificationMessage) async throws {
        guard let session = state.withLock({ $0.session }) else {
            throw AccessoryMessage.Error.transportUnavailable
        }
        let payload = Data(AccessoryNotificationCodec.encode(message))
        try await session.send(message: AccessoryMessage {
            AccessoryMessage.Payload(transport: .bluetooth, data: payload)
        })
    }
}

extension ForwardedNotification {
    init(_ notification: AccessoryNotification, shouldAlert: Bool) {
        self.init(
            identifier: notification.identifier.notificationIdentifier,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body?.string,
            sourceName: notification.sourceName,
            sourceIdentifier: notification.identifier.sourceIdentifier,
            shouldAlert: shouldAlert,
            actions: notification.actions.map { action in
                let collectsText = if case .textInput = action.type { true } else { false }
                return Action(identifier: action.identifier, title: action.title ?? "", collectsText: collectsText)
            }
        )
    }
}
#endif
