/// A notification iOS forwarded through AccessoryNotifications, as the watch is
/// sent it.
package struct ForwardedNotification: Equatable, Sendable {
    package struct Action: Equatable, Sendable {
        package var identifier: String
        package var title: String
        /// A text-input action: the watch offers its reply menu and sends the
        /// chosen text back with the action.
        package var collectsText: Bool

        package init(identifier: String, title: String, collectsText: Bool) {
            self.identifier = identifier
            self.title = title
            self.collectsText = collectsText
        }
    }

    package var identifier: String
    package var title: String?
    package var subtitle: String?
    package var body: String?
    package var sourceName: String?
    package var sourceIdentifier: String?
    package var shouldAlert: Bool
    package var actions: [Action]

    package init(
        identifier: String,
        title: String?,
        subtitle: String?,
        body: String?,
        sourceName: String?,
        sourceIdentifier: String?,
        shouldAlert: Bool,
        actions: [Action]
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sourceName = sourceName
        self.sourceIdentifier = sourceIdentifier
        self.shouldAlert = shouldAlert
        self.actions = actions
    }
}

package enum AccessoryNotificationMessage: Equatable, Sendable {
    case present(ForwardedNotification)
    case remove(sourceIdentifier: String, notificationIdentifier: String)
    case removeAll
}

/// What the watch sends back when an action of a forwarded notification is
/// chosen.
package struct AccessoryNotificationReply: Equatable, Sendable {
    package var notificationIdentifier: String
    package var actionIdentifier: String
    /// Nil for a plain action, and for a text-input one left empty.
    package var text: String?

    package init(notificationIdentifier: String, actionIdentifier: String, text: String?) {
        self.notificationIdentifier = notificationIdentifier
        self.actionIdentifier = actionIdentifier
        self.text = text
    }
}

/// The plaintext inside an AccessoryNotifications message — sealed by iOS, opened
/// by the watch's `accessory_notifications.c`, whose parser is the other half of
/// this file.
package enum AccessoryNotificationCodec {
    static let presentType: UInt8 = 0x01
    static let removeType: UInt8 = 0x02
    static let removeAllType: UInt8 = 0x03

    static let titleTag: UInt8 = 0x01
    static let subtitleTag: UInt8 = 0x02
    static let bodyTag: UInt8 = 0x03
    static let sourceTag: UInt8 = 0x04
    static let identifierTag: UInt8 = 0x05
    static let alertTag: UInt8 = 0x06
    static let actionTag: UInt8 = 0x07
    static let sourceIdentifierTag: UInt8 = 0x08

    static let textInputFlag: UInt8 = 0x01

    /// `AN_MAX_ACTIONS`: the watch keeps the first four and drops the rest.
    package static let maximumActionCount = 4

    package static func encode(_ message: AccessoryNotificationMessage) -> [UInt8] {
        switch message {
        case .present(let notification):
            present(notification)
        case .remove(let sourceIdentifier, let notificationIdentifier):
            [removeType] + identifierBytes(
                sourceIdentifier: sourceIdentifier,
                notificationIdentifier: notificationIdentifier
            )
        case .removeAll:
            [removeAllType]
        }
    }

    /// `u8 notification_id_len | notification_id | u8 action_id_len | action_id |
    /// u16 text_len (LE) | text`, from `accessory_notifications_invoke_action`.
    package static func decodeReply(_ bytes: [UInt8]) throws -> AccessoryNotificationReply {
        var reader = bytes[...]
        let notificationIdentifier = try lengthPrefixed(&reader)
        let actionIdentifier = try lengthPrefixed(&reader)
        var text: String?
        if reader.count >= 2 {
            let length = Int(UInt16(littleEndianBytes: reader.prefix(2)))
            reader = reader.dropFirst(2)
            guard reader.count >= length else { throw AccessoryNotificationCodecError.truncated }
            if length > 0 {
                text = String(decoding: reader.prefix(length), as: UTF8.self)
            }
        }
        return AccessoryNotificationReply(
            notificationIdentifier: notificationIdentifier,
            actionIdentifier: actionIdentifier,
            text: text
        )
    }

    private static func present(_ notification: ForwardedNotification) -> [UInt8] {
        var bytes = [presentType]
        func append(_ tag: UInt8, _ value: [UInt8]) {
            guard !value.isEmpty else { return }
            bytes += [tag, UInt8(value.count)] + value
        }
        // `MAX_ATTRIBUTE_LENGTHS` for the three the watch has a limit for; the
        // length byte for the rest. Either way the cut has to fall between
        // characters.
        append(titleTag, text(notification.title, maximumByteCount: 64))
        append(subtitleTag, text(notification.subtitle, maximumByteCount: 64))
        append(bodyTag, text(notification.body, maximumByteCount: 255))
        append(sourceTag, text(notification.sourceName, maximumByteCount: 64))
        // Not the length byte's 255: the watch keys the app's notification
        // preferences by it, and ignores one longer than a settings key
        // (`SETTINGS_KEY_MAX_LEN`), which leaves the reader no Mute.
        append(sourceIdentifierTag, text(notification.sourceIdentifier, maximumByteCount: 127))
        append(identifierTag, identifierBytes(
            sourceIdentifier: notification.sourceIdentifier ?? "",
            notificationIdentifier: notification.identifier
        ))
        append(alertTag, [notification.shouldAlert ? 1 : 0])
        for action in notification.actions.compactMap(actionEntry).prefix(maximumActionCount) {
            append(actionTag, action)
        }
        return bytes
    }

    /// Nil for an action the watch could not show or could not answer: a row with
    /// no title is blank and unselectable, and an identifier cut short comes back
    /// as one iOS never issued.
    private static func actionEntry(_ action: ForwardedNotification.Action) -> [UInt8]? {
        let title = text(action.title, maximumByteCount: 64)
        let identifier = Array(action.identifier.utf8)
        // flags, two length bytes and the title have to fit beside it in one TLV.
        guard !title.isEmpty, identifier.count <= 255 - 3 - title.count else { return nil }
        return [action.collectsText ? textInputFlag : 0, UInt8(identifier.count)] + identifier
            + [UInt8(title.count)] + title
    }

    /// The identifier as the watch holds it, and as a reply names the notification.
    package static func identifierOnTheWatch(sourceIdentifier: String, notificationIdentifier: String) -> String {
        String(
            decoding: identifierBytes(sourceIdentifier: sourceIdentifier, notificationIdentifier: notificationIdentifier),
            as: UTF8.self
        )
    }

    /// The watch derives a notification's UUID from these bytes alone, so a
    /// present and the remove that follows it have to cut the same identifier the
    /// same way. The source is in it because iOS scopes an identifier to its app:
    /// sent alone, two apps' "1" were one notification on the watch, each
    /// overwriting the other. U+001F cannot occur in a bundle identifier, so no
    /// two pairs make the same bytes.
    private static func identifierBytes(sourceIdentifier: String, notificationIdentifier: String) -> [UInt8] {
        (sourceIdentifier + "\u{1F}" + notificationIdentifier).utf8BytesEndingOnACharacter(maximumByteCount: 255)
    }

    private static func text(_ value: String?, maximumByteCount: Int) -> [UInt8] {
        value?.utf8BytesEndingOnACharacter(maximumByteCount: maximumByteCount) ?? []
    }

    private static func lengthPrefixed(_ reader: inout ArraySlice<UInt8>) throws -> String {
        guard let length = reader.first.map(Int.init), reader.count > length else {
            throw AccessoryNotificationCodecError.truncated
        }
        let value = String(decoding: reader.dropFirst().prefix(length), as: UTF8.self)
        reader = reader.dropFirst(1 + length)
        return value
    }
}

package enum AccessoryNotificationCodecError: Error, Equatable, Sendable {
    case truncated
}
