import MemberwiseInit

public enum PutBytesObjectType: UInt8, Equatable, Sendable {
    case firmware = 0x01
    case recovery = 0x02
    case systemResource = 0x03
    case appResource = 0x04
    case appExecutable = 0x05
    case file = 0x06
    case worker = 0x07
}

public enum PutBytesResult: UInt8, Equatable, Sendable {
    case acknowledgement = 0x01
    case negativeAcknowledgement = 0x02
}

@MemberwiseInit(.public)
public struct PutBytesResponse: Equatable, Sendable {
    public var result: PutBytesResult
    public var cookie: UInt32
}

public enum PutBytesCodec {
    public static var endpoint: UInt16 { 0xBEEF }

    public static func appInitializationFrame(
        objectSize: UInt32,
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x01]
                + bigEndianBytes(of: objectSize)
                + [objectType.rawValue | 0x80]
                + bigEndianBytes(of: appBankID)
        )
    }

    public static func systemInitializationFrame(
        objectSize: UInt32,
        objectType: PutBytesObjectType,
        bank: UInt8
    ) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x01] + bigEndianBytes(of: objectSize) + [objectType.rawValue, bank]
        )
    }

    /// Starts a transfer of a named file, which is how a language pack is sent:
    /// the firmware stores `ObjectFile` under the name given here.
    ///
    /// The name follows the bank byte and is read with `strlen`, so the
    /// terminator is part of the message rather than optional.
    public static func fileInitializationFrame(
        objectSize: UInt32,
        filename: String,
        bank: UInt8 = 0
    ) throws -> PebbleProtocolFrame {
        let name = Array(filename.utf8)
        guard !name.isEmpty, !name.contains(0) else {
            throw PutBytesCodecError.invalidFilename
        }
        return PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x01]
                + bigEndianBytes(of: objectSize)
                + [PutBytesObjectType.file.rawValue, bank]
                + name
                + [0x00]
        )
    }

    public static func putFrame(cookie: UInt32, bytes: [UInt8]) throws -> PebbleProtocolFrame {
        guard let payloadSize = UInt32(exactly: bytes.count) else {
            throw PutBytesCodecError.payloadTooLarge
        }
        return PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x02]
                + bigEndianBytes(of: cookie)
                + bigEndianBytes(of: payloadSize)
                + bytes
        )
    }

    public static func commitFrame(cookie: UInt32, crc: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x03] + bigEndianBytes(of: cookie) + bigEndianBytes(of: crc)
        )
    }

    public static func abortFrame(cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x04] + bigEndianBytes(of: cookie))
    }

    public static func installFrame(cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x05] + bigEndianBytes(of: cookie))
    }

    public static func decodeResponse(_ frame: PebbleProtocolFrame) throws -> PutBytesResponse {
        guard frame.endpoint == endpoint else {
            throw PutBytesCodecError.unexpectedEndpoint
        }
        guard frame.payload.count == 5,
              let result = PutBytesResult(rawValue: frame.payload[0]) else {
            throw PutBytesCodecError.invalidPayload
        }
        return PutBytesResponse(
            result: result,
            cookie: uint32(from: frame.payload[1..<5])
        )
    }

    private static func bigEndianBytes(of value: UInt32) -> [UInt8] {
        [
            UInt8(value >> 24),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static func uint32(from bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { value, byte in
            value << 8 | UInt32(byte)
        }
    }
}

public enum PutBytesCodecError: Error, Equatable, Sendable {
    case payloadTooLarge
    case unexpectedEndpoint
    case invalidPayload
    case invalidFilename
}
