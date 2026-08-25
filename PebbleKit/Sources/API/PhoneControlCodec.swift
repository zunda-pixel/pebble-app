public import Foundation
import MemberwiseInit

public enum PhoneCallAction: Equatable, Sendable {
    case answer(cookie: UInt32)
    case hangup(cookie: UInt32)
}

public enum PhoneControlCodec {
    public static var endpoint: UInt16 { 33 }

    // The reference implementation caps caller strings at 31 characters.
    static let maximumTextLength = 31

    public static func decode(_ frame: PebbleProtocolFrame) throws -> PhoneCallAction {
        guard frame.endpoint == endpoint else {
            throw PhoneControlCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 5 else {
            throw PhoneControlCodecError.invalidPayload
        }
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

    public static func missedCallFrame(
        cookie: UInt32,
        callerNumber: String,
        callerName: String?
    ) -> PebbleProtocolFrame {
        callFrame(
            command: 0x06,
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
        let number = String(callerNumber.prefix(maximumTextLength))
        let name = String((callerName ?? callerNumber).prefix(maximumTextLength))
        var payload: [UInt8] = [command] + cookie.bigEndianBytes
        payload.append(contentsOf: pascalString(number))
        payload.append(contentsOf: pascalString(name))
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    private static func pascalString(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8.prefix(255))
        return [UInt8(bytes.count)] + bytes
    }
}

public enum PhoneControlCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: bigEndian) { Array($0) }
    }
}
