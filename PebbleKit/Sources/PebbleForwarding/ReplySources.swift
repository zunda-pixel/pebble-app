#if os(iOS)
import AccessoryNotifications
import Foundation
import PebbleProtocol

/// Which forwarded notification a reply from the watch is about.
///
/// The watch answers with the notification's identifier alone, cut to what its
/// length byte holds, and iOS wants the response keyed by source as well. The
/// extension that asked is often not the process that hears the answer, so the
/// mapping is kept in the extension's own defaults rather than in memory.
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
        identifiers.last { AccessoryNotificationCodec.identifierOnTheWatch($0.notificationIdentifier) == identifier }
    }

    mutating func remember(_ identifier: AccessoryNotification.Identifier) {
        identifiers.removeAll { $0 == identifier }
        identifiers.append(identifier)
        identifiers = Array(identifiers.suffix(Self.limit))
        save()
    }

    mutating func forget(_ notificationIdentifier: String) {
        identifiers.removeAll { $0.notificationIdentifier == notificationIdentifier }
        save()
    }

    mutating func forgetAll() {
        identifiers = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(identifiers), forKey: Self.key)
    }
}
#endif
