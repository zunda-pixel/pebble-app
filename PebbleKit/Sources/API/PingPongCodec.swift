public enum PingPongMessage: Equatable, Sendable {
    case ping(cookie: UInt32)
    case pong(cookie: UInt32)
}

public enum PingPongCodec {
    public static var endpoint: UInt16 { 2_001 }

    public static func frame(for message: PingPongMessage) -> PebbleProtocolFrame {
        let command: UInt8
        let cookie: UInt32
        switch message {
        case .ping(let value):
            command = 0
            cookie = value
        case .pong(let value):
            command = 1
            cookie = value
        }

        return PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [
                command,
                UInt8(cookie >> 24),
                UInt8((cookie >> 16) & 0xFF),
                UInt8((cookie >> 8) & 0xFF),
                UInt8(cookie & 0xFF),
            ]
        )
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> PingPongMessage {
        guard frame.endpoint == endpoint else {
            throw PingPongCodecError.unexpectedEndpoint
        }
        guard frame.payload.count == 5 else {
            throw PingPongCodecError.invalidPayload
        }

        let cookie = UInt32(frame.payload[1]) << 24
            | UInt32(frame.payload[2]) << 16
            | UInt32(frame.payload[3]) << 8
            | UInt32(frame.payload[4])

        switch frame.payload[0] {
        case 0:
            return .ping(cookie: cookie)
        case 1:
            return .pong(cookie: cookie)
        default:
            throw PingPongCodecError.unknownCommand
        }
    }
}

public enum PingPongCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}
