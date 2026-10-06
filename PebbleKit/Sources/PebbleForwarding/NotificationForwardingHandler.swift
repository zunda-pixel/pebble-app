#if os(iOS)
public import AccessoryNotifications
public import AccessoryTransportExtension
import DequeModule
import Foundation
import OSLog
import PebbleProtocol
import Synchronization

/// The AccessoryDataProvider's part: each notification iOS forwards is written
/// in the form the watch parses, and each action the watch sends back is
/// answered to iOS as the response to that notification.
///
/// Every message goes out through one queue, in the order iOS handed them over.
/// A task per message raced: a removal could reach the watch before the update
/// it followed, and the update then brought the notification back.
public final class NotificationForwardingHandler: NotificationsForwarding.AccessoryNotificationsHandler {
    private struct Outgoing: Sendable {
        var message: AccessoryNotificationMessage
        /// Told whether the watch took it, for the one call iOS waits on.
        var delivered: CheckedContinuation<Bool, Never>?
    }

    private struct State {
        var session: NotificationsForwarding.Session?
        var queue: Deque<Outgoing> = []
        /// Nil outside a session, which is what refuses a message then.
        var wake: AsyncStream<Void>.Continuation?
        /// Which drain may take from the queue. A drain still sending when its
        /// session ended went on popping beside the next session's, and a
        /// removal could then reach the watch before the present it follows.
        var generation = 0
    }

    private let state = Mutex(State())
    private let sources = ReplySources()
    private let replySuggester: any ReplySuggesting

    public convenience init() {
        self.init(replySuggester: StoredReplies())
    }

    init(replySuggester: any ReplySuggesting) {
        self.replySuggester = replySuggester
    }

    public func didActivate(for session: NotificationsForwarding.Session) {
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // One queue has one reader: a second, started beside a first still
        // draining, would take messages off the same front out of order.
        let generation: Int? = state.withLock { state in
            state.session = session
            guard state.wake == nil else { return nil }
            state.wake = wake
            state.generation += 1
            return state.generation
        }
        guard let generation else { return }
        Task { [weak self] in
            for await _ in wakes {
                await self?.drain(generation)
            }
        }
    }

    public func didInvalidate() {
        let (abandoned, wake) = state.withLock { state in
            let taken = (state.queue, state.wake)
            state.session = nil
            state.queue = []
            state.wake = nil
            state.generation += 1
            return taken
        }
        wake?.finish()
        for outgoing in abandoned {
            outgoing.delivered?.resume(returning: false)
        }
    }

    public func addNotification(
        _ notification: AccessoryNotification,
        alertingContext: AlertingContext
    ) async throws -> Bool {
        remember(notification)
        let forwarded = ForwardedNotification(notification, shouldAlert: alertingContext.shouldAlert)
        return await withCheckedContinuation { delivered in
            enqueue(Outgoing(message: .present(forwarded), delivered: delivered))
        }
    }

    public func updateNotification(_ notification: AccessoryNotification) {
        remember(notification)
        enqueue(Outgoing(message: .present(ForwardedNotification(notification, shouldAlert: false))))
    }

    public func removeNotification(identifier: AccessoryNotification.Identifier) {
        sources.forget(identifier)
        enqueue(Outgoing(message: .remove(
            sourceIdentifier: identifier.sourceIdentifier,
            notificationIdentifier: identifier.notificationIdentifier
        )))
    }

    public func removeAllNotifications() {
        sources.forgetAll()
        enqueue(Outgoing(message: .removeAll))
    }

    public func messageHandler(_ message: TransportMessage) {
        let reply: AccessoryNotificationReply
        do {
            reply = try AccessoryNotificationCodec.decodeReply([UInt8](message.data))
        } catch {
            forwardingLog.error("the watch sent a reply that could not be read")
            return
        }
        let session = state.withLock { $0.session }
        let notification = sources.notification(onTheWatchAs: reply.notificationIdentifier)
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
        sources.remember(notification.identifier)
    }

    private func enqueue(_ outgoing: Outgoing) {
        let isQueued = state.withLock { state in
            guard let wake = state.wake else { return false }
            state.queue.append(outgoing)
            wake.yield()
            return true
        }
        if !isQueued {
            forwardingLog.error("a message for the watch arrived outside a session")
            outgoing.delivered?.resume(returning: false)
        }
    }

    /// Takes each message off the front as it goes, so the one sent is the one
    /// removed whatever was queued behind it meanwhile.
    private func drain(_ generation: Int) async {
        while let outgoing = state.withLock({ $0.generation == generation ? $0.queue.popFirst() : nil }) {
            let isDelivered: Bool
            do {
                try await send(await withReplies(outgoing.message), generation: generation)
                isDelivered = true
            } catch {
                forwardingLog.error("a message did not reach the watch: \(String(describing: error), privacy: .public)")
                isDelivered = false
            }
            outgoing.delivered?.resume(returning: isDelivered)
        }
    }

    /// Decided here rather than as the message is queued, so that a removal
    /// queued while the replies are being chosen still follows the present.
    private func withReplies(_ message: AccessoryNotificationMessage) async -> AccessoryNotificationMessage {
        guard case .present(var notification) = message,
              notification.actions.contains(where: \.collectsText) else {
            return message
        }
        notification.replies = await replySuggester.replies(for: notification)
        return .present(notification)
    }

    /// A message taken in an ended session fails rather than going out in the
    /// next, where that session's own drain may already have sent what came
    /// after it.
    private func send(_ message: AccessoryNotificationMessage, generation: Int) async throws {
        guard let session = state.withLock({ $0.generation == generation ? $0.session : nil }) else {
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
