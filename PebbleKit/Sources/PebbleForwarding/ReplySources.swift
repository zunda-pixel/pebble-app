#if os(iOS)
import AccessoryNotifications
import Foundation
import PebbleProtocol

/// Which forwarded notification a reply from the watch is about.
///
/// The watch answers with the identifier it was sent — source and notification
/// together, cut to what its length byte holds — and iOS wants the response
/// keyed by the two apart. The extension that asked is often not the process
/// that hears the answer, so the mapping is kept in the extension's own
/// defaults rather than in memory.
struct ReplySources {
    /// Well past what a watch keeps: `AN_MAX_TRACKED` forgets beyond 64.
    static let limit = 256
    private static let key = "forwardedNotificationIdentifiers"

    private var identifiers: [AccessoryNotification.Identifier]

    init() {
        identifiers = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([AccessoryNotification.Identifier].self, from: $0) } ?? []
    }

    func notification(onTheWatchAs identifier: String) -> AccessoryNotification.Identifier? {
        identifiers.last { Self.identifierOnTheWatch($0) == identifier }
    }

    mutating func remember(_ identifier: AccessoryNotification.Identifier) {
        identifiers.removeAll { $0 == identifier }
        identifiers.append(identifier)
        identifiers = Array(identifiers.suffix(Self.limit))
        save()
    }

    mutating func forget(_ identifier: AccessoryNotification.Identifier) {
        identifiers.removeAll { $0 == identifier }
        save()
    }

    mutating func forgetAll() {
        identifiers = []
        save()
    }

    static func identifierOnTheWatch(_ identifier: AccessoryNotification.Identifier) -> String {
        AccessoryNotificationCodec.identifierOnTheWatch(
            sourceIdentifier: identifier.sourceIdentifier,
            notificationIdentifier: identifier.notificationIdentifier
        )
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(identifiers), forKey: Self.key)
    }
}
#endif
