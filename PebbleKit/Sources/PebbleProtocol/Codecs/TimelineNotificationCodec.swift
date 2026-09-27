public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct TimelineNotification: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var parentApplicationID: UUID
    public var timestamp: Date = Date()
    public var title: String
    public var body: String
    public var appName: String?

    public func encoded() throws -> [UInt8] {
        var attributes: [[UInt8]] = []
        attributes.append(TimelineItemHeader.textAttribute(id: 0x01, value: title, maximumByteCount: 64))
        attributes.append(TimelineItemHeader.textAttribute(id: 0x03, value: body, maximumByteCount: 512))
        if let appName, !appName.isEmpty {
            attributes.append(TimelineItemHeader.textAttribute(id: 0x1E, value: appName, maximumByteCount: 40))
        }
        let attributeBytes = attributes.flatMap { $0 }
        guard let dataLength = UInt16(exactly: attributeBytes.count) else {
            throw TimelineNotificationCodecError.payloadTooLarge
        }
        let seconds = timestamp.timeIntervalSince1970.rounded()
        guard seconds >= 0, seconds <= Double(UInt32.max) else {
            throw TimelineNotificationCodecError.invalidTimestamp
        }

        let header = TimelineItemHeader(
            id: id,
            parentApplicationID: parentApplicationID,
            timestamp: UInt32(seconds),
            durationMinutes: 0,
            kind: .notification,
            flags: 0,
            layout: 0x04, // genericNotification
            payloadLength: dataLength,
            attributeCount: UInt8(attributes.count),
            // No actions; iOS handles ANCS actions outside the companion app.
            actionCount: 0
        )
        return header.encoded + attributeBytes
    }
}

public enum TimelineNotificationCodec {
    public static var databaseID: UInt8 { 0x04 }

    public static func insertFrame(
        _ notification: TimelineNotification,
        token: UInt16
    ) throws -> PebbleProtocolFrame {
        try BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: notification.id.bytes,
            value: try notification.encoded(),
            token: token
        )
    }
}

public enum TimelineNotificationCodecError: Error, Equatable, Sendable {
    case invalidTimestamp
    case payloadTooLarge
}
