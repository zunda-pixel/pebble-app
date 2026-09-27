public import Foundation

public enum AppRunStateEvent: Equatable, Sendable {
    case started(UUID)
    case stopped(UUID)
}

public enum AppRunStateCodec {
    public static var endpoint: UInt16 { 52 }

    public static func startFrame(applicationID: UUID) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + applicationID.bytes)
    }

    public static func stopFrame(applicationID: UUID) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x02] + applicationID.bytes)
    }

    public static func requestFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x03])
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> AppRunStateEvent {
        guard frame.endpoint == endpoint, frame.payload.count >= 17 else {
            throw AppRunStateCodecError.invalidPayload
        }
        guard let id = UUID(bytes: frame.payload[1..<17]) else {
            throw AppRunStateCodecError.invalidPayload
        }
        switch frame.payload[0] {
        case 0x01: return .started(id)
        case 0x02: return .stopped(id)
        default: throw AppRunStateCodecError.invalidPayload
        }
    }
}

public enum AppRunStateCodecError: Error, Equatable, Sendable { case invalidPayload }
