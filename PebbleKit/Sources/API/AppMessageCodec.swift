public import Foundation
import MemberwiseInit

public enum AppMessageValue: Codable, Equatable, Sendable {
    case bytes([UInt8])
    case string(String)
    case unsigned(UInt32)
    case signed(Int32)
}

@MemberwiseInit(.public)
public struct AppMessageTuple: Codable, Equatable, Sendable {
    public var key: UInt32
    public var value: AppMessageValue
}

@MemberwiseInit(.public)
public struct AppMessageData: Codable, Equatable, Sendable {
    public var transactionID: UInt8
    public var applicationID: UUID
    public var tuples: [AppMessageTuple]
}

public enum AppMessagePacket: Equatable, Sendable {
    case push(AppMessageData)
    case acknowledgement(transactionID: UInt8)
    case negativeAcknowledgement(transactionID: UInt8)
}

public enum AppMessageCodec {
    public static var endpoint: UInt16 { 48 }

    public static func pushFrame(_ message: AppMessageData) throws -> PebbleProtocolFrame {
        guard message.tuples.count <= Int(UInt8.max) else {
            throw AppMessageCodecError.tooManyTuples
        }
        var payload: [UInt8] = [0x01, message.transactionID]
        payload.append(contentsOf: uuidBytes(message.applicationID))
        payload.append(UInt8(message.tuples.count))
        for tuple in message.tuples {
            payload.append(contentsOf: try encode(tuple))
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func resultFrame(transactionID: UInt8, acknowledged: Bool) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [acknowledged ? 0xFF : 0x7F, transactionID]
        )
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> AppMessagePacket {
        guard frame.endpoint == endpoint else {
            throw AppMessageCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 2 else {
            throw AppMessageCodecError.invalidPayload
        }
        switch frame.payload[0] {
        case 0xFF:
            guard frame.payload.count == 2 else { throw AppMessageCodecError.invalidPayload }
            return .acknowledgement(transactionID: frame.payload[1])
        case 0x7F:
            guard frame.payload.count == 2 else { throw AppMessageCodecError.invalidPayload }
            return .negativeAcknowledgement(transactionID: frame.payload[1])
        case 0x01:
            return .push(try decodePush(frame.payload))
        default:
            throw AppMessageCodecError.unknownCommand
        }
    }

    private static func encode(_ tuple: AppMessageTuple) throws -> [UInt8] {
        let type: UInt8
        let data: [UInt8]
        switch tuple.value {
        case .bytes(let bytes):
            type = 0
            data = bytes
        case .string(let string):
            type = 1
            data = Array(string.utf8) + [0]
        case .unsigned(let value):
            type = 2
            data = value.littleEndianBytes
        case .signed(let value):
            type = 3
            // Always four bytes: a narrower width would put the sign in its own top bit,
            // and there is nothing to be saved by making the watch work that out.
            data = UInt32(bitPattern: value).littleEndianBytes
        }
        guard let length = UInt16(exactly: data.count) else {
            throw AppMessageCodecError.valueTooLarge
        }
        return tuple.key.littleEndianBytes
            + [type]
            + length.littleEndianBytes
            + data
    }

    private static func decodePush(_ payload: [UInt8]) throws -> AppMessageData {
        guard payload.count >= 19,
              let applicationID = uuid(from: payload[2..<18]) else {
            throw AppMessageCodecError.invalidPayload
        }
        let count = Int(payload[18])
        var offset = 19
        var tuples: [AppMessageTuple] = []
        tuples.reserveCapacity(count)
        for _ in 0..<count {
            guard payload.count >= offset + 7 else { throw AppMessageCodecError.invalidPayload }
            let key = littleEndianUInt32(payload[offset..<(offset + 4)])
            let type = payload[offset + 4]
            let length = Int(littleEndianUInt16(payload[(offset + 5)..<(offset + 7)]))
            offset += 7
            guard payload.count >= offset + length else { throw AppMessageCodecError.invalidPayload }
            let data = Array(payload[offset..<(offset + length)])
            tuples.append(AppMessageTuple(key: key, value: try decodeValue(type: type, data: data)))
            offset += length
        }
        guard offset == payload.count else { throw AppMessageCodecError.invalidPayload }
        return AppMessageData(
            transactionID: payload[1],
            applicationID: applicationID,
            tuples: tuples
        )
    }

    private static func decodeValue(type: UInt8, data: [UInt8]) throws -> AppMessageValue {
        switch type {
        case 0:
            return .bytes(data)
        case 1:
            guard data.last == 0,
                  let value = String(bytes: data.dropLast(), encoding: .utf8) else {
                throw AppMessageCodecError.invalidString
            }
            return .string(value)
        case 2:
            return .unsigned(try decodeUnsigned(data))
        case 3:
            return .signed(try decodeSigned(data))
        default:
            throw AppMessageCodecError.unknownTupleType
        }
    }

    // A watchapp writes a signed value in whatever width it asked for, so the
    // sign sits in the top bit of the last byte that arrived:
    // `dict_write_int(iter, key, &value, 1, true)` with -1 sends 0xFF alone.
    private static func decodeSigned(_ data: [UInt8]) throws -> Int32 {
        let value = try decodeUnsigned(data)
        let unusedBits = 32 - data.count * 8
        return Int32(bitPattern: value << unusedBits) >> unusedBits
    }

    private static func decodeUnsigned(_ data: [UInt8]) throws -> UInt32 {
        guard [1, 2, 4].contains(data.count) else {
            throw AppMessageCodecError.invalidNumberSize
        }
        return data.enumerated().reduce(into: UInt32(0)) { result, item in
            result |= UInt32(item.element) << UInt32(item.offset * 8)
        }
    }

    private static func littleEndianUInt16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
    }

    private static func littleEndianUInt32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.enumerated().reduce(into: UInt32(0)) { result, item in
            result |= UInt32(item.element) << UInt32(item.offset * 8)
        }
    }

    private static func uuidBytes(_ uuid: UUID) -> [UInt8] {
        uuid.uuidString.filter { $0 != "-" }.appMessageChunks(ofCount: 2)
            .compactMap { UInt8($0, radix: 16) }
    }

    private static func uuid(from bytes: ArraySlice<UInt8>) -> UUID? {
        let digits = Array("0123456789ABCDEF")
        let value = String(bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
        return UUID(uuidString: "\(value.prefix(8))-\(value.dropFirst(8).prefix(4))-\(value.dropFirst(12).prefix(4))-\(value.dropFirst(16).prefix(4))-\(value.dropFirst(20))")
    }
}

public enum AppMessageCodecError: Error, Equatable, Sendable {
    case tooManyTuples
    case valueTooLarge
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
    case unknownTupleType
    case invalidString
    case invalidNumberSize
}

private extension String {
    func appMessageChunks(ofCount count: Int) -> [Substring] {
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
