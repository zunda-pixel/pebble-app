public import Foundation
import MemberwiseInit

/// What a timeline item is, as the firmware numbers them. The number decides
/// how the watch presents the item, and has to agree with the database it is
/// filed in: a pin in the reminder database is neither one thing nor the other.
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
    /// Whether the watch shows this as a pin on the timeline or as a reminder,
    /// which is a different database and a different presentation.
    public var kind: PebbleTimelineItemType = .pin

    public func encoded() throws -> [UInt8] {
        var attributes = [textAttribute(id: 0x01, value: title, limit: 64)]
        if let subtitle { attributes.append(textAttribute(id: 0x02, value: subtitle, limit: 128)) }
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
        let content = Array(value.utf8.prefix(limit))
        return [id] + UInt16(content.count).littleEndianBytes + content
    }
}

public enum TimelinePinCodec {
    /// Pins live in their own database. They were being written to the
    /// reminder database, which stores them but shows them as something else.
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
}

/// A reminder is the same item in a database of its own: the watch keeps a
/// window of them around the present and shows each one when its time comes,
/// rather than listing it on the timeline.
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

    public init(fileURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? base.appending(path: "Pebble/timeline.json")
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
}
