import Foundation

public enum PhoneCallAction: Equatable, Sendable {
    case answer(cookie: UInt32)
    case hangup(cookie: UInt32)
}

public enum PhoneControlCodec {
    public static var endpoint: UInt16 { 33 }

    // The firmware copies each caller string into a 32-byte buffer and writes
    // its NUL at index 31 (`CALLER_BUFFER_LENGTH`, `get_call_info_from_msg` in
    // `services/phone_pp/service.c`), so 31 *bytes* survive. Capping at 31
    // characters, as the reference app does, lets a Japanese name be cut
    // mid-character there and drawn as nothing.
    static let maximumTextByteCount = 31

    public static func decode(_ frame: PebbleProtocolFrame) throws -> PhoneCallAction {
        guard frame.endpoint == endpoint else {
            throw PhoneControlCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 5 else {
            throw PhoneControlCodecError.invalidPayload
        }
        // The firmware reads the cookie natively, little-endian
        // (`*((uint32_t *)msg)`), so this value is byte-swapped against its
        // idea of it. That is harmless only because neither side interprets
        // it: the watch echoes the four bytes back as it received them.
        let cookie = UInt32(frame.payload[1]) << 24
            | UInt32(frame.payload[2]) << 16
            | UInt32(frame.payload[3]) << 8
            | UInt32(frame.payload[4])
        switch frame.payload[0] {
        case 0x01:
            return .answer(cookie: cookie)
        case 0x02:
            return .hangup(cookie: cookie)
        default:
            throw PhoneControlCodecError.unknownCommand
        }
    }

    public static func incomingCallFrame(
        cookie: UInt32,
        callerNumber: String,
        callerName: String?
    ) -> PebbleProtocolFrame {
        callFrame(
            command: 0x04,
            cookie: cookie,
            callerNumber: callerNumber,
            callerName: callerName
        )
    }

    public static func callStartFrame(cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x08] + cookie.bigEndianBytes)
    }

    public static func callEndFrame(cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x09] + cookie.bigEndianBytes)
    }

    private static func callFrame(
        command: UInt8,
        cookie: UInt32,
        callerNumber: String,
        callerName: String?
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [command] + cookie.bigEndianBytes
        payload.append(contentsOf: pascalString(callerNumber))
        payload.append(contentsOf: pascalString(callerName ?? callerNumber))
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    private static func pascalString(_ value: String) -> [UInt8] {
        let bytes = value.utf8BytesEndingOnACharacter(maximumByteCount: maximumTextByteCount)
        return [UInt8(bytes.count)] + bytes
    }
}

public enum PhoneControlCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}
