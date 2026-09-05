public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PBWBinaryHeader: Equatable, Sendable {
    public var headerVersionMajor: UInt8
    public var headerVersionMinor: UInt8
    public var sdkVersionMajor: UInt8
    public var sdkVersionMinor: UInt8
    public var appVersionMajor: UInt8
    public var appVersionMinor: UInt8
    public var iconResourceID: UInt32
    public var flags: UInt32
    public var applicationID: UUID

    public func appMetadata(name: String) -> PebbleAppMetadata {
        PebbleAppMetadata(
            applicationID: applicationID,
            flags: flags,
            iconResourceID: iconResourceID,
            appVersionMajor: appVersionMajor,
            appVersionMinor: appVersionMinor,
            sdkVersionMajor: sdkVersionMajor,
            sdkVersionMinor: sdkVersionMinor,
            name: name
        )
    }
}

public enum PBWBinaryHeaderDecoder {
    public static var size: Int { 120 }
    private static var sentinel: [UInt8] { [0x50, 0x42, 0x4C, 0x41, 0x50, 0x50, 0x00, 0x00] }

    public static func decode(from data: Data) throws -> PBWBinaryHeader {
        let bytes = [UInt8](data)
        guard bytes.count >= size else {
            throw PBWBinaryHeaderError.invalidSize
        }
        guard Array(bytes[0..<8]) == sentinel else {
            throw PBWBinaryHeaderError.invalidSentinel
        }
        guard let applicationID = uuid(from: bytes[104..<120]) else {
            throw PBWBinaryHeaderError.invalidUUID
        }

        return PBWBinaryHeader(
            headerVersionMajor: bytes[8],
            headerVersionMinor: bytes[9],
            sdkVersionMajor: bytes[10],
            sdkVersionMinor: bytes[11],
            appVersionMajor: bytes[12],
            appVersionMinor: bytes[13],
            iconResourceID: littleEndianUInt32(bytes[88..<92]),
            flags: littleEndianUInt32(bytes[96..<100]),
            applicationID: applicationID
        )
    }

    private static func littleEndianUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(into: UInt32(0)) { value, item in
            value |= UInt32(item.element) << UInt32(item.offset * 8)
        }
    }

    private static func uuid(from bytes: ArraySlice<UInt8>) -> UUID? {
        let hexadecimalDigits = Array("0123456789ABCDEF")
        let hex = bytes.flatMap { byte in
            [hexadecimalDigits[Int(byte >> 4)], hexadecimalDigits[Int(byte & 0x0F)]]
        }
        let value = String(hex)
        return UUID(uuidString: "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))")
    }
}

public enum PBWBinaryHeaderError: Error, Equatable, Sendable {
    case invalidSize
    case invalidSentinel
    case invalidUUID
}
