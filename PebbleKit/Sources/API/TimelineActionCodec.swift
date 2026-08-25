public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct TimelineActionInvocation: Equatable, Sendable {
    public var itemID: UUID
    public var actionID: UInt8
}

public enum TimelineActionCodec {
    public static var endpoint: UInt16 { 11_440 }
    public static func decode(_ frame: PebbleProtocolFrame) throws -> TimelineActionInvocation {
        guard frame.endpoint == endpoint, frame.payload.count >= 19, frame.payload[0] == 0x02 else {
            throw TimelineActionCodecError.invalidPayload
        }
        let hex = frame.payload[1..<17].map { String(format: "%02x", $0) }.joined()
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: formatted) else { throw TimelineActionCodecError.invalidPayload }
        return TimelineActionInvocation(itemID: id, actionID: frame.payload[17])
    }
    public static func responseFrame(itemID: UUID, succeeded: Bool) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x11] + BlobDBCodec.uuidBytes(itemID) + [succeeded ? 1 : 0, 0])
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
