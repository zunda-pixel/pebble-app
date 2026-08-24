public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleTimelineNotification: Equatable, Sendable {
    public var id: UUID = UUID()
    public var parentApplicationID: UUID
    public var timestamp: Date = Date()
    public var title: String
    public var body: String
    public var appName: String?

    public func encoded() throws -> [UInt8] {
        var attributes: [[UInt8]] = []
        attributes.append(Self.textAttribute(id: 0x01, value: title, maximumByteCount: 64))
        attributes.append(Self.textAttribute(id: 0x03, value: body, maximumByteCount: 512))
        if let appName, !appName.isEmpty {
            attributes.append(Self.textAttribute(id: 0x1E, value: appName, maximumByteCount: 40))
        }
        let attributeBytes = attributes.flatMap { $0 }
        guard let dataLength = UInt16(exactly: attributeBytes.count) else {
            throw TimelineNotificationCodecError.payloadTooLarge
        }
        let seconds = timestamp.timeIntervalSince1970.rounded()
        guard seconds >= 0, seconds <= Double(UInt32.max) else {
            throw TimelineNotificationCodecError.invalidTimestamp
        }

        var bytes = BlobDBCodec.uuidBytes(id)
        bytes.append(contentsOf: BlobDBCodec.uuidBytes(parentApplicationID))
        bytes.append(contentsOf: UInt32(seconds).littleEndianBytes)
        bytes.append(contentsOf: UInt16(0).littleEndianBytes)
        bytes.append(0x01) // Timeline item type: notification.
        bytes.append(contentsOf: UInt16(0).littleEndianBytes)
        bytes.append(0x04) // Layout: genericNotification.
        bytes.append(contentsOf: dataLength.littleEndianBytes)
        bytes.append(UInt8(attributes.count))
        bytes.append(0) // No actions; iOS handles ANCS actions outside the companion app.
        bytes.append(contentsOf: attributeBytes)
        return bytes
    }

    private static func textAttribute(
        id: UInt8,
        value: String,
        maximumByteCount: Int
    ) -> [UInt8] {
        var content: [UInt8] = []
        for character in value {
            let bytes = Array(String(character).utf8)
            guard content.count + bytes.count <= maximumByteCount else { break }
            content.append(contentsOf: bytes)
        }
        return [id] + UInt16(content.count).littleEndianBytes + content
    }
}

public enum TimelineNotificationCodec {
    public static var databaseID: UInt8 { 0x04 }

    public static func insertFrame(
        _ notification: PebbleTimelineNotification,
        token: UInt16
    ) throws -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: BlobDBCodec.uuidBytes(notification.id),
            value: try notification.encoded(),
            token: token
        )
    }
}

public enum TimelineNotificationCodecError: Error, Equatable, Sendable {
    case invalidTimestamp
    case payloadTooLarge
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}
