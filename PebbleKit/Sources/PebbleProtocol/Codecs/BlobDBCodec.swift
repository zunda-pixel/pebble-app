public import Foundation
import CryptoKit
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
public struct ApplicationMetadata: Equatable, Sendable {
    public var applicationID: UUID
    public var flags: UInt32
    public var iconResourceID: UInt32
    public var appVersionMajor: UInt8
    public var appVersionMinor: UInt8
    public var sdkVersionMajor: UInt8
    public var sdkVersionMinor: UInt8
    public var name: String

    /// What `WatchApplicationLibrary` compares against the registration it
    /// last wrote to a watch.
    public var writtenDigest: String {
        SHA256.hash(data: Data(encoded())).hexadecimalString
    }

    public func encoded() -> [UInt8] {
        var bytes = applicationID.bytes
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
        metadata: ApplicationMetadata,
        token: UInt16
    ) -> PebbleProtocolFrame {
        uncheckedInsertFrame(
            databaseID: applicationDatabaseID,
            key: metadata.applicationID.bytes,
            value: metadata.encoded(),
            token: token
        )
    }

    public static func insertFrame(
        databaseID: UInt8,
        key: [UInt8],
        value: [UInt8],
        token: UInt16
    ) throws -> PebbleProtocolFrame {
        guard key.count <= Int(UInt8.max) else { throw BlobDBCodecError.keyTooLong }
        guard value.count <= Int(UInt16.max) else { throw BlobDBCodecError.valueTooLarge }
        return uncheckedInsertFrame(databaseID: databaseID, key: key, value: value, token: token)
    }

    public static func deleteApplicationFrame(
        applicationID: UUID,
        token: UInt16
    ) -> PebbleProtocolFrame {
        uncheckedDeleteFrame(databaseID: applicationDatabaseID, key: applicationID.bytes, token: token)
    }

    public static func deleteFrame(databaseID: UInt8, key: [UInt8], token: UInt16) throws -> PebbleProtocolFrame {
        guard key.count <= Int(UInt8.max) else { throw BlobDBCodecError.keyTooLong }
        return uncheckedDeleteFrame(databaseID: databaseID, key: key, token: token)
    }

    // For a record whose key and value this module lays out at a size that
    // cannot vary — a UUID key, a settings name, a packed struct. Going through
    // the throwing builders there would put a `try` on every settings write for
    // a length check that can never fail; a length that does vary with what the
    // reader has (a bundle ID, a pin's text) goes through them instead.
    static func uncheckedInsertFrame(
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

    static func uncheckedDeleteFrame(databaseID: UInt8, key: [UInt8], token: UInt16) -> PebbleProtocolFrame {
        var payload = commonHeader(command: 0x04, token: token, databaseID: databaseID)
        payload.append(UInt8(key.count))
        payload.append(contentsOf: key)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    /// Empties one database. `0x05 <token> <databaseID>` — the firmware
    /// documents it in `services/blob_db/endpoint.c`, and it takes no key: this
    /// removes what other sources put there too.
    public static func clearFrame(databaseID: UInt8, token: UInt16) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: commonHeader(command: 0x05, token: token, databaseID: databaseID)
        )
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
    /// Longer than the key's one length byte can say.
    case keyTooLong
    /// Longer than the value's two length bytes can say.
    case valueTooLarge
}
