public import Foundation
import MemberwiseInit

/// The number decides how the watch presents the item, and has to agree with
/// the database it is filed in.
public enum PebbleTimelineItemType: UInt8, Codable, Equatable, Sendable {
    case notification = 1
    case pin = 2
    case reminder = 3
}

@MemberwiseInit(.public)
public struct PebbleTimelinePin: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var parentApplicationID: UUID
    public var timestamp: Date
    public var durationMinutes: UInt16 = 0
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var isAllDay: Bool = false
    public var kind: PebbleTimelineItemType = .pin
    /// Whether the watch made this one rather than the app.
    ///
    /// Such an item has actions and an icon the watch chose and this app does
    /// not model, so sending it back would replace what the watch has with a
    /// poorer copy of it. It is kept, shown and deletable; it is not written.
    public var isFromWatch: Bool = false

    public func encoded() throws -> [UInt8] {
        // `MAX_ATTRIBUTE_LENGTHS`. The firmware cuts anything longer itself, and cuts
        // it mid-character.
        var attributes = [textAttribute(id: 0x01, value: title, limit: 64)]
        if let subtitle { attributes.append(textAttribute(id: 0x02, value: subtitle, limit: 64)) }
        if let body { attributes.append(textAttribute(id: 0x03, value: body, limit: 512)) }
        let attributeBytes = attributes.flatMap { $0 }
        guard let length = UInt16(exactly: attributeBytes.count) else { throw TimelinePinError.payloadTooLarge }
        let seconds = timestamp.timeIntervalSince1970.rounded()
        guard seconds >= 0, seconds <= Double(UInt32.max) else { throw TimelinePinError.invalidTimestamp }
        var bytes = BlobDBCodec.uuidBytes(id)
        bytes += BlobDBCodec.uuidBytes(parentApplicationID)
        bytes += UInt32(seconds).littleEndianBytes
        bytes += durationMinutes.littleEndianBytes
        bytes.append(kind.rawValue)
        bytes += UInt16(isAllDay ? 1 << 2 : 0).littleEndianBytes
        bytes.append(0x01)
        bytes += length.littleEndianBytes
        bytes.append(UInt8(attributes.count))
        bytes.append(0)
        bytes += attributeBytes
        return bytes
    }

    private func textAttribute(id: UInt8, value: String, limit: Int) -> [UInt8] {
        let content = value.utf8BytesEndingOnACharacter(maximumByteCount: limit)
        return [id] + UInt16(content.count).littleEndianBytes + content
    }

    /// Reads an item the watch serialized (`SerializedTimelineItemHeader` in
    /// `services/timeline/item.h`, then the attributes, then the actions).
    ///
    /// The icon, the colour and the actions are read past rather than kept:
    /// what this app has a place for is the text and the time. `isFromWatch`
    /// records that there is more to the item than what was kept, so that
    /// nothing here writes it back.
    public init(decoding bytes: [UInt8]) throws {
        guard bytes.count >= Self.headerLength else {
            throw TimelinePinError.malformedItem
        }
        guard let kind = PebbleTimelineItemType(rawValue: bytes[38]) else {
            throw TimelinePinError.malformedItem
        }
        id = try Self.uuid(bytes[0..<16])
        parentApplicationID = try Self.uuid(bytes[16..<32])
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
        var offset = Self.headerLength
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

    /// `CommonTimelineItemHeader` plus the payload length and the two counts.
    private static var headerLength: Int { 46 }

    private static func uuid(_ bytes: ArraySlice<UInt8>) throws -> UUID {
        let dashed = [8, 4, 4, 4, 12].reduce(into: (rest: Substring(bytes.hexadecimalString), parts: [Substring]())) {
            state, count in
            state.parts.append(state.rest.prefix(count))
            state.rest = state.rest.dropFirst(count)
        }.parts.joined(separator: "-")
        guard let uuid = UUID(uuidString: dashed) else {
            throw TimelinePinError.malformedItem
        }
        return uuid
    }
}

public enum TimelinePinCodec {
    /// The reminder database stores a pin but shows it as something else.
    public static var databaseID: UInt8 { 0x01 }

    public static func insertFrame(_ pin: PebbleTimelinePin, token: UInt16) throws -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: BlobDBCodec.uuidBytes(pin.id),
            value: try pin.encoded(),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(databaseID: databaseID, key: BlobDBCodec.uuidBytes(id), token: token)
    }

    public static func clearFrame(token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.clearFrame(databaseID: databaseID, token: token)
    }
}

/// The watch keeps a window of reminders around the present and shows each one
/// when its time comes, rather than listing it on the timeline.
public enum TimelineReminderCodec {
    public static var databaseID: UInt8 { 0x03 }

    public static func insertFrame(
        _ reminder: PebbleTimelinePin,
        token: UInt16
    ) throws -> PebbleProtocolFrame {
        var reminder = reminder
        reminder.kind = .reminder
        return BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: BlobDBCodec.uuidBytes(reminder.id),
            value: try reminder.encoded(),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(databaseID: databaseID, key: BlobDBCodec.uuidBytes(id), token: token)
    }
}

public actor TimelinePinLibrary {
    private var fileURL: URL
    /// Which pin the app last gave which watch. BlobDB cannot be listed, so
    /// without this there is no way to name a pin the watch has and the app has
    /// forgotten — and a delete is only queued at the moment a pin is let go of,
    /// which is no help if that moment was missed or the queue was lost.
    private var writtenURL: URL
    /// Which item in the phone's own app stands for which one here.
    ///
    /// The two are one reminder kept in two places, and neither knows the
    /// other's name: without this an edit becomes a second reminder, and a
    /// reminder let go of on one side cannot be found on the other.
    private var mirroredURL: URL

    public init(fileURL: URL? = nil, writtenURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let items = fileURL ?? base.appending(path: "Pebble/timeline.json")
        self.fileURL = items
        // Named after the items it accounts for: pins and reminders are two of
        // these libraries, and one shared file would have each claiming to have
        // written the other's.
        self.writtenURL = writtenURL ?? items
            .deletingLastPathComponent()
            .appending(path: "\(items.deletingPathExtension().lastPathComponent)-written.json")
        self.mirroredURL = items
            .deletingLastPathComponent()
            .appending(path: "\(items.deletingPathExtension().lastPathComponent)-mirrored.json")
    }

    public func mirroredIdentifiers() throws -> [UUID: String] {
        try PersistentJSON.loadRecovering([UUID: String].self, from: mirroredURL) ?? [:]
    }

    public func setMirroredIdentifiers(_ identifiers: [UUID: String]) throws {
        try PersistentJSON.save(identifiers, to: mirroredURL)
    }

    public func writtenPinIDs(deviceID: String) throws -> Set<UUID> {
        Set(try writtenStates()[deviceID] ?? [])
    }

    public func setWrittenPinIDs(_ pinIDs: Set<UUID>, deviceID: String) throws {
        var states = try writtenStates()
        states[deviceID] = Array(pinIDs)
        try PersistentJSON.save(states, to: writtenURL)
    }

    public func forgetWrittenPinIDs(deviceID: String) throws {
        var states = try writtenStates()
        states[deviceID] = nil
        try PersistentJSON.save(states, to: writtenURL)
    }

    private func writtenStates() throws -> [String: [UUID]] {
        try PersistentJSON.loadRecovering([String: [UUID]].self, from: writtenURL) ?? [:]
    }

    public func pins() throws -> [PebbleTimelinePin] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([PebbleTimelinePin].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ pins: [PebbleTimelinePin]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pins).write(to: fileURL, options: .atomic)
    }
}

public enum TimelinePinError: Error, Equatable, Sendable {
    case invalidTimestamp
    case payloadTooLarge
    /// An item the watch sent that this app could not read as one.
    case malformedItem
}

extension String {
    /// A cut inside a multi-byte character leaves the watch a byte it cannot read
    /// as the start of one: `utf8_get_bounds` fails and the text layout draws
    /// nothing at all, so a Japanese title one character too long would vanish
    /// rather than lose its tail.
    func utf8BytesEndingOnACharacter(maximumByteCount limit: Int) -> [UInt8] {
        var content: [UInt8] = []
        for character in self {
            let bytes = Array(String(character).utf8)
            guard content.count + bytes.count <= limit else { break }
            content.append(contentsOf: bytes)
        }
        return content
    }
}
