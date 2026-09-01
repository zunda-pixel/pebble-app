public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct TimelineActionInvocation: Equatable, Sendable {
    public var itemID: UUID
    public var actionID: UInt8
    /// What the watch sent along with the action, by attribute id — a snooze
    /// carries the new time, for instance.
    public var attributes: [UInt8: [UInt8]] = [:]
}

public enum TimelineActionCodec {
    public static var endpoint: UInt16 { 11_440 }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> TimelineActionInvocation {
        guard frame.endpoint == endpoint, frame.payload.count >= 19, frame.payload[0] == 0x02 else {
            throw TimelineActionCodecError.invalidPayload
        }
        let hex = frame.payload[1..<17].hexadecimalString
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: formatted) else { throw TimelineActionCodecError.invalidPayload }

        var attributes: [UInt8: [UInt8]] = [:]
        var offset = 19
        for _ in 0..<Int(frame.payload[18]) {
            guard frame.payload.count >= offset + 3 else { break }
            let attributeID = frame.payload[offset]
            let length = Int(frame.payload[offset + 1]) | Int(frame.payload[offset + 2]) << 8
            offset += 3
            guard frame.payload.count >= offset + length else { break }
            attributes[attributeID] = Array(frame.payload[offset..<offset + length])
            offset += length
        }
        return TimelineActionInvocation(
            itemID: id,
            actionID: frame.payload[17],
            attributes: attributes
        )
    }

    /// Tells the watch how the action went, and what to show while it says so.
    ///
    /// Zero is the acknowledgement and one the refusal — the way round that
    /// reads backwards, and was backwards here.
    public static func responseFrame(
        itemID: UUID,
        succeeded: Bool,
        subtitle: String? = nil
    ) -> PebbleProtocolFrame {
        var attributes: [[UInt8]] = []
        if let subtitle {
            let content = Array(subtitle.utf8.prefix(64))
            attributes.append([0x02] + UInt16(content.count).littleEndianBytes + content)
        }
        var payload: [UInt8] = [0x11]
        payload += BlobDBCodec.uuidBytes(itemID)
        payload.append(succeeded ? 0 : 1)
        payload.append(UInt8(attributes.count))
        payload += attributes.flatMap { $0 }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }
}
public enum TimelineActionCodecError: Error, Equatable, Sendable { case invalidPayload }

public enum HealthSyncResponseCodec {
    public static func decode(_ frame: PebbleProtocolFrame) throws -> Bool {
        guard frame.endpoint == HealthSyncCodec.endpoint, frame.payload.count >= 2, frame.payload[0] == 0x11 else {
            throw HealthSyncResponseError.invalidPayload
        }
        return frame.payload[1] == 0x01
    }
}
public enum HealthSyncResponseError: Error, Equatable, Sendable { case invalidPayload }
