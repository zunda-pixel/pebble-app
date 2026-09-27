public import Foundation
import CryptoKit
import MemberwiseInit

/// The number decides how the watch presents the item, and has to agree with
/// the database it is filed in.
public enum TimelineItemKind: UInt8, Codable, Equatable, Sendable {
    case notification = 1
    case pin = 2
    case reminder = 3
}

@MemberwiseInit(.public)
public struct TimelinePin: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var parentApplicationID: UUID
    public var timestamp: Date
    public var durationMinutes: UInt16 = 0
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var isAllDay: Bool = false
    public var kind: TimelineItemKind = .pin
    /// Whether the watch made this one rather than the app.
    ///
    /// Such an item has actions and an icon the watch chose and this app does
    /// not model, so sending it back would replace what the watch has with a
    /// poorer copy of it. It is kept, shown and deletable; it is not written.
    public var isFromWatch: Bool = false
    /// What a reminder's Dismiss says on the watch, in the reader's language.
    ///
    /// Given at the moment of writing rather than kept: the language is the
    /// phone's, now, and a label stored with the reminder would go on in the
    /// language it was made in. Nil sends the action without a title, which
    /// firmware since fe7224b labels in the watch's own language
    /// (`timeline_actions_add_action_to_root_level`, `timeline_actions.c`) —
    /// and firmware before it labels "[Action]".
    public var dismissTitle: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, parentApplicationID, timestamp, durationMinutes, title, subtitle, body
        case isAllDay, kind, isFromWatch
    }

    /// A digest of the bytes this pin is written to the watch as.
    ///
    /// Its own `Hashable` conformance would do for one run and not for two:
    /// Swift seeds that per process, and this is written to disk and read back
    /// after a launch to decide whether the watch already holds the pin.
    public var writtenDigest: String {
        guard let value = try? encoded() else {
            // A pin that cannot be encoded cannot be written either, so it must
            // not read as one the watch already holds. No digest is empty.
            return ""
        }
        return SHA256.hash(data: Data(value)).hexadecimalString
    }

    public func encoded() throws -> [UInt8] {
        // `MAX_ATTRIBUTE_LENGTHS`. The firmware cuts anything longer itself, and cuts
        // it mid-character.
        var attributes = [TimelineItemHeader.textAttribute(id: 0x01, value: title, maximumByteCount: 64)]
        if let subtitle {
            attributes.append(TimelineItemHeader.textAttribute(id: 0x02, value: subtitle, maximumByteCount: 64))
        }
        if let body {
            attributes.append(TimelineItemHeader.textAttribute(id: 0x03, value: body, maximumByteCount: 512))
        }
        let attributeBytes = attributes.flatMap { $0 }
        // A reminder with no action of its own has no menu on the watch at
        // all: `notification_window.c` hides the popup's action button unless
        // the item carries at least one, and Snooze — which the firmware adds
        // by itself — only ever appears inside that menu. So every reminder
        // carries a Dismiss (`SerializedActionHeader`: id, type 0x04, then its
        // attributes — the label, where there is one).
        let actionBytes: [UInt8]
        if kind == .reminder {
            let label = dismissTitle.map {
                TimelineItemHeader.textAttribute(id: 0x01, value: $0, maximumByteCount: 64)
            }
            actionBytes = [0x01, 0x04, label == nil ? 0x00 : 0x01] + (label ?? [])
        } else {
            actionBytes = []
        }
        let actionCount: UInt8 = kind == .reminder ? 1 : 0
        guard let length = UInt16(exactly: attributeBytes.count + actionBytes.count) else {
            throw TimelinePinError.payloadTooLarge
        }
        let seconds = timestamp.timeIntervalSince1970.rounded()
        guard seconds >= 0, seconds <= Double(UInt32.max) else { throw TimelinePinError.invalidTimestamp }
        let header = TimelineItemHeader(
            id: id,
            parentApplicationID: parentApplicationID,
            timestamp: UInt32(seconds),
            durationMinutes: durationMinutes,
            kind: kind,
            flags: isAllDay ? 1 << 2 : 0,
            // A reminder is `LayoutIdReminder`, as the firmware's own
            // (`reminder.c`) are, not the `LayoutIdGeneric` a pin gets. The
            // popup picks its own layout today (`notification_window.c`), so
            // Generic went unseen there.
            layout: kind == .reminder ? 0x03 : 0x01,
            payloadLength: length,
            attributeCount: UInt8(attributes.count),
            actionCount: actionCount
        )
        return header.encoded + attributeBytes + actionBytes
    }

    /// Reads an item the watch serialized (`SerializedTimelineItemHeader` in
    /// `services/timeline/item.h`, then the attributes, then the actions).
    ///
    /// The icon, the colour and the actions are read past rather than kept:
    /// what this app has a place for is the text and the time. `isFromWatch`
    /// records that there is more to the item than what was kept, so that
    /// nothing here writes it back.
    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= TimelineItemHeader.length else {
            throw TimelinePinError.malformedItem
        }
        guard let kind = TimelineItemKind(rawValue: bytes[38]) else {
            throw TimelinePinError.malformedItem
        }
        guard let id = UUID(bytes: bytes[0..<16]),
              let parentApplicationID = UUID(bytes: bytes[16..<32]) else {
            throw TimelinePinError.malformedItem
        }
        self.id = id
        self.parentApplicationID = parentApplicationID
        let seconds = UInt32(bytes[32])
            | UInt32(bytes[33]) << 8
            | UInt32(bytes[34]) << 16
            | UInt32(bytes[35]) << 24
        timestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
        durationMinutes = UInt16(bytes[36]) | UInt16(bytes[37]) << 8
        self.kind = kind
        let flags = bytes[39]
        isAllDay = flags & (1 << 2) != 0
        isFromWatch = flags & (1 << 3) != 0

        var spokenTitle: String?
        var offset = TimelineItemHeader.length
        for _ in 0..<Int(bytes[44]) {
            guard bytes.count >= offset + 3 else {
                throw TimelinePinError.malformedItem
            }
            let attribute = bytes[offset]
            let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
            offset += 3
            guard bytes.count >= offset + length else {
                throw TimelinePinError.malformedItem
            }
            let text = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
            offset += length
            switch attribute {
            case 0x01: spokenTitle = text
            case 0x02: subtitle = text
            case 0x03: body = text
            default: continue
            }
        }
        // An item with nothing to read is not one this app can show, and the
        // watch always titles what it makes.
        guard let spokenTitle, !spokenTitle.isEmpty else {
            throw TimelinePinError.malformedItem
        }
        title = spokenTitle
    }
}

public extension TimelinePin {
    // Not the synthesized decoder: that reads a field with a default through
    // `decode`, so a file written before the field existed fails to decode and
    // `PersistentJSON.loadRecovering` sets the whole file aside.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        parentApplicationID = try container.decode(UUID.self, forKey: .parentApplicationID)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        durationMinutes = try container.decodeIfPresent(UInt16.self, forKey: .durationMinutes) ?? 0
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        isAllDay = try container.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        kind = try container.decodeIfPresent(TimelineItemKind.self, forKey: .kind) ?? .pin
        isFromWatch = try container.decodeIfPresent(Bool.self, forKey: .isFromWatch) ?? false
    }
}

public enum TimelinePinCodec {
    public static var databaseID: UInt8 { 0x01 }

    public static func insertFrame(_ pin: TimelinePin, token: UInt16) throws -> PebbleProtocolFrame {
        try BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: pin.id.bytes,
            value: try pin.encoded(),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedDeleteFrame(databaseID: databaseID, key: id.bytes, token: token)
    }

    public static func clearFrame(token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.clearFrame(databaseID: databaseID, token: token)
    }
}

public enum TimelinePinError: Error, Equatable, Sendable {
    case invalidTimestamp
    case payloadTooLarge
    /// An item the watch sent that this app could not read as one.
    case malformedItem
}
