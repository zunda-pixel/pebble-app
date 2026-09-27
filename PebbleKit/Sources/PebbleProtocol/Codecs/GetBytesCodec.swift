// No request for a file by name: `get_bytes.c` serves one only outside
// `CONFIG_RELEASE`, so a shipping watch refuses it.
public enum GetBytesRequest: Equatable, Sendable {
    case coredump
    /// The watch marks a crash as read once it has handed it over.
    case unreadCoredump

    var command: UInt8 {
        switch self {
        case .coredump: 0x00
        case .unreadCoredump: 0x05
        }
    }
}

/// The watch answers with how many bytes there are and then sends them in
/// chunks, each saying where it belongs.
public enum GetBytesCodec {
    public static var endpoint: UInt16 { 9_000 }

    static let objectInfoCommand: UInt8 = 0x01
    static let objectDataCommand: UInt8 = 0x02

    // The size arrives as a 32-bit number and is believed before a byte of the
    // object has; the largest flash a Pebble has is 32 MiB.
    static let maximumObjectByteCount = 32 * 1_024 * 1_024

    public static func requestFrame(_ request: GetBytesRequest, transactionID: UInt8) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [request.command, transactionID])
    }
}

public struct GetBytesCollector: WatchPullCollector {
    private let transactionID: UInt8
    private var expectedByteCount: Int?
    private var bytes: [UInt8] = []

    public init(transactionID: UInt8) {
        self.transactionID = transactionID
    }

    // A frame for another transaction is ignored rather than refused: an answer
    // to a request that has already been given up on is not an error.
    public mutating func accept(_ frame: PebbleProtocolFrame) throws -> [UInt8]? {
        guard frame.endpoint == GetBytesCodec.endpoint else {
            throw GetBytesError.unexpectedEndpoint
        }
        guard frame.payload.count >= 2, frame.payload[1] == transactionID else { return nil }

        switch frame.payload[0] {
        case GetBytesCodec.objectInfoCommand:
            guard frame.payload.count >= 7 else { throw GetBytesError.invalidPayload }
            let error = frame.payload[2]
            guard error == 0 else { throw GetBytesError.refused(error) }
            let count = Int(UInt32(bigEndianBytes: frame.payload[3..<7]))
            guard count <= GetBytesCodec.maximumObjectByteCount else {
                throw GetBytesError.objectTooLarge(count)
            }
            expectedByteCount = count
            bytes.reserveCapacity(count)
            // A watch with nothing to send says there is none of it and sends no chunks.
            return count == 0 ? [] : nil
        case GetBytesCodec.objectDataCommand:
            guard frame.payload.count >= 6, let expected = expectedByteCount else {
                throw GetBytesError.invalidPayload
            }
            let offset = Int(UInt32(bigEndianBytes: frame.payload[2..<6]))
            guard offset == bytes.count else { throw GetBytesError.outOfOrderChunk }
            bytes += frame.payload.dropFirst(6)
            return bytes.count >= expected ? Array(bytes.prefix(expected)) : nil
        default:
            return nil
        }
    }
}

public enum GetBytesError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case outOfOrderChunk
    case objectTooLarge(Int)
    /// One means the watch did not understand the request, two that it is already
    /// sending something, three that there is no such object, four that what it
    /// has is corrupt.
    case refused(UInt8)
}
