#if os(iOS)
import AccessoryNotifications
import Foundation
import PebbleProtocol
import Synchronization

/// Which forwarded notification a reply from the watch is about.
///
/// The watch answers with the identifier it was sent — source and notification
/// together, cut to what its length byte holds — and iOS wants the response
/// keyed by the two apart. The extension that asked is often not the process
/// that hears the answer, so the mapping is kept in the extension's own
/// defaults rather than in memory, and read from them afresh every time: a
/// copy read once when the handler was made never saw what another process
/// remembered, and wrote its own stale list over that process's.
struct ReplySources: Sendable {
    /// Well past what a watch keeps: `AN_MAX_TRACKED` forgets beyond 64.
    static let limit = 256
    private static let key = "forwardedNotificationIdentifiers"
    /// Keeps this process's read-modify-writes from interleaving; the
    /// defaults themselves are what other processes share.
    private static let lock = Mutex(())

    func notification(onTheWatchAs identifier: String) -> AccessoryNotification.Identifier? {
        Self.stored().last { Self.identifierOnTheWatch($0) == identifier }
    }

    func remember(_ identifier: AccessoryNotification.Identifier) {
        Self.modify { identifiers in
            identifiers.removeAll { $0 == identifier }
            identifiers.append(identifier)
            identifiers = Array(identifiers.suffix(Self.limit))
        }
    }

    func forget(_ identifier: AccessoryNotification.Identifier) {
        Self.modify { identifiers in
            identifiers.removeAll { $0 == identifier }
        }
    }

    func forgetAll() {
        Self.modify { identifiers in
            identifiers = []
        }
    }

    static func identifierOnTheWatch(_ identifier: AccessoryNotification.Identifier) -> String {
        AccessoryNotificationCodec.identifierOnTheWatch(
            sourceIdentifier: identifier.sourceIdentifier,
            notificationIdentifier: identifier.notificationIdentifier
        )
    }

    private static func stored() -> [AccessoryNotification.Identifier] {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([AccessoryNotification.Identifier].self, from: $0) } ?? []
    }

    private static func modify(_ change: (inout [AccessoryNotification.Identifier]) -> Void) {
        lock.withLock { _ in
            var identifiers = stored()
            change(&identifiers)
            UserDefaults.standard.set(try? JSONEncoder().encode(identifiers), forKey: key)
        }
    }
}
#endif
