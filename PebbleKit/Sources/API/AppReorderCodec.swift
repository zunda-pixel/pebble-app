public import Foundation

public enum AppReorderResult: UInt8, Equatable, Sendable {
    case success = 0x01
    case failed = 0x02
    case invalid = 0x03
    case retry = 0x04
}

public enum AppReorderCodec {
    public static var endpoint: UInt16 { 0xABCD }

    public static func frame(applicationIDs: [UUID]) throws -> PebbleProtocolFrame {
        guard applicationIDs.count <= Int(UInt8.max) else {
            throw AppReorderCodecError.tooManyApplications
        }

        var payload: [UInt8] = [0x01, UInt8(applicationIDs.count)]
        for applicationID in applicationIDs {
            payload.append(contentsOf: bytes(of: applicationID))
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func decodeResult(_ frame: PebbleProtocolFrame) throws -> AppReorderResult {
        guard frame.endpoint == endpoint else {
            throw AppReorderCodecError.unexpectedEndpoint
        }
        guard frame.payload.count == 1 else {
            throw AppReorderCodecError.invalidPayload
        }
        guard let result = AppReorderResult(rawValue: frame.payload[0]) else {
            throw AppReorderCodecError.unknownResult
        }
        return result
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        uuid.uuidString
            .filter { $0 != "-" }
            .chunks(ofCount: 2)
            .compactMap { UInt8($0, radix: 16) }
    }
}

public enum AppReorderCodecError: Error, Equatable, Sendable {
    case tooManyApplications
    case unexpectedEndpoint
    case invalidPayload
    case unknownResult
}

private extension String {
    func chunks(ofCount count: Int) -> [Substring] {
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
