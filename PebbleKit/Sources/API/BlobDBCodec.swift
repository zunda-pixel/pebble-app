public import Foundation
import MemberwiseInit

public enum BlobDBStatus: UInt8, Equatable, Sendable {
    case success = 0x01
    case generalFailure = 0x02
    case invalidOperation = 0x03
    case invalidDatabaseID = 0x04
    case invalidData = 0x05
    case keyDoesNotExist = 0x06
    case databaseFull = 0x07
    case dataStale = 0x08
    case notSupported = 0x09
    case locked = 0x0A
    case tryLater = 0x0B
}

@MemberwiseInit(.public)
public struct BlobDBResponse: Equatable, Sendable {
    public var token: UInt16
    public var status: BlobDBStatus
}

@MemberwiseInit(.public)
public struct PebbleAppMetadata: Equatable, Sendable {
    public var applicationID: UUID
    public var flags: UInt32
    public var iconResourceID: UInt32
    public var appVersionMajor: UInt8
    public var appVersionMinor: UInt8
    public var sdkVersionMajor: UInt8
    public var sdkVersionMinor: UInt8
    public var name: String

    public func encoded() -> [UInt8] {
        var bytes = BlobDBCodec.uuidBytes(applicationID)
        bytes.append(contentsOf: flags.littleEndianBytes)
        bytes.append(contentsOf: iconResourceID.littleEndianBytes)
        bytes.append(appVersionMajor)
        bytes.append(appVersionMinor)
        bytes.append(sdkVersionMajor)
        bytes.append(sdkVersionMinor)
        bytes.append(0)
        bytes.append(0)
        bytes.append(contentsOf: fixedNameBytes)
        return bytes
    }

    private var fixedNameBytes: [UInt8] {
        var bytes: [UInt8] = []
        for character in name {
            let characterBytes = Array(String(character).utf8)
            guard bytes.count + characterBytes.count <= 95 else { break }
            bytes.append(contentsOf: characterBytes)
        }
        bytes.append(0)
        bytes.append(contentsOf: repeatElement(0, count: 96 - bytes.count))
        return bytes
    }
}

public enum BlobDBCodec {
    public static var endpoint: UInt16 { 0xB1DB }
    public static var applicationDatabaseID: UInt8 { 0x02 }

    public static func insertApplicationFrame(
        metadata: PebbleAppMetadata,
        token: UInt16
    ) -> PebbleProtocolFrame {
        insertFrame(
            databaseID: applicationDatabaseID,
            key: uuidBytes(metadata.applicationID),
            value: metadata.encoded(),
            token: token
        )
    }

    public static func insertFrame(
        databaseID: UInt8,
        key: [UInt8],
        value: [UInt8],
        token: UInt16
    ) -> PebbleProtocolFrame {
        var payload = commonHeader(command: 0x01, token: token, databaseID: databaseID)
        payload.append(UInt8(key.count))
        payload.append(contentsOf: key)
        payload.append(contentsOf: UInt16(value.count).littleEndianBytes)
        payload.append(contentsOf: value)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func deleteApplicationFrame(
        applicationID: UUID,
        token: UInt16
    ) -> PebbleProtocolFrame {
        let key = uuidBytes(applicationID)
        var payload = commonHeader(
            command: 0x04,
            token: token,
            databaseID: applicationDatabaseID
        )
        payload.append(UInt8(key.count))
        payload.append(contentsOf: key)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func decodeResponse(_ frame: PebbleProtocolFrame) throws -> BlobDBResponse {
        guard frame.endpoint == endpoint else {
            throw BlobDBCodecError.unexpectedEndpoint
        }
        guard frame.payload.count == 3 else {
            throw BlobDBCodecError.invalidPayload
        }
        guard let status = BlobDBStatus(rawValue: frame.payload[2]) else {
            throw BlobDBCodecError.unknownStatus
        }
        let token = UInt16(frame.payload[0]) << 8 | UInt16(frame.payload[1])
        return BlobDBResponse(token: token, status: status)
    }

    static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        uuid.uuidString
            .filter { $0 != "-" }
            .strideChunks(ofCount: 2)
            .compactMap { UInt8($0, radix: 16) }
    }

    private static func commonHeader(
        command: UInt8,
        token: UInt16,
        databaseID: UInt8
    ) -> [UInt8] {
        [command, UInt8(token >> 8), UInt8(token & 0xFF), databaseID]
    }
}

public enum BlobDBCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownStatus
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

private extension String {
    func strideChunks(ofCount count: Int) -> [Substring] {
        var chunks: [Substring] = []
        var start = startIndex
        while start < endIndex {
            let end = index(start, offsetBy: count, limitedBy: endIndex) ?? endIndex
            chunks.append(self[start..<end])
            start = end
        }
        return chunks
    }
}
