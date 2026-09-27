import MemberwiseInit

public enum BlobDB2Message: Equatable, Sendable {
    case write(BlobDB2Write)
    case writeBack(BlobDB2Write)
    case syncDone(tokenBytes: [UInt8])
}

@MemberwiseInit(.public)
public struct BlobDB2Write: Equatable, Sendable {
    public var tokenBytes: [UInt8]
    public var databaseID: UInt8
    public var timestamp: UInt32
    public var key: [UInt8]
    public var value: [UInt8]
}

/// The watch pushes its own records on this endpoint and expects an
/// acknowledgement for each.
public enum BlobDB2Codec {
    public static var endpoint: UInt16 { 0xB2DB }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> BlobDB2Message {
        guard frame.endpoint == endpoint else {
            throw BlobDB2CodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 3 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let tokenBytes = Array(frame.payload[1...2])
        switch frame.payload[0] {
        case 0x08:
            return .write(try decodeWrite(frame.payload, tokenBytes: tokenBytes))
        case 0x09:
            return .writeBack(try decodeWrite(frame.payload, tokenBytes: tokenBytes))
        case 0x0A:
            return .syncDone(tokenBytes: tokenBytes)
        default:
            throw BlobDB2CodecError.unsupportedCommand
        }
    }

    public static func responseFrame(
        to message: BlobDB2Message,
        succeeded: Bool
    ) -> PebbleProtocolFrame {
        let command: UInt8
        let tokenBytes: [UInt8]
        switch message {
        case .write(let write):
            command = 0x88
            tokenBytes = write.tokenBytes
        case .writeBack(let write):
            command = 0x89
            tokenBytes = write.tokenBytes
        case .syncDone(let bytes):
            command = 0x8A
            tokenBytes = bytes
        }
        let status: UInt8 = succeeded ? 0x01 : 0x05
        return PebbleProtocolFrame(endpoint: endpoint, payload: [command] + tokenBytes + [status])
    }

    private static func decodeWrite(_ payload: [UInt8], tokenBytes: [UInt8]) throws -> BlobDB2Write {
        guard payload.count >= 9 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let databaseID = payload[3]
        let timestamp = UInt32(payload[4])
            | UInt32(payload[5]) << 8
            | UInt32(payload[6]) << 16
            | UInt32(payload[7]) << 24
        let keySize = Int(payload[8])
        var offset = 9
        guard payload.count >= offset + keySize + 2 else {
            throw BlobDB2CodecError.invalidPayload
        }
        let key = Array(payload[offset..<offset + keySize])
        offset += keySize
        let valueSize = Int(payload[offset]) | Int(payload[offset + 1]) << 8
        offset += 2
        guard payload.count >= offset + valueSize else {
            throw BlobDB2CodecError.invalidPayload
        }
        let value = Array(payload[offset..<offset + valueSize])
        return BlobDB2Write(
            tokenBytes: tokenBytes,
            databaseID: databaseID,
            timestamp: timestamp,
            key: key,
            value: value
        )
    }
}

public enum BlobDB2CodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unsupportedCommand
}
