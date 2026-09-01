/// What to ask the watch for.
public enum GetBytesRequest: Equatable, Sendable {
    /// The last crash the watch saved, whether or not it has been read before.
    case coredump
    /// The last crash, but only if nobody has read it yet. The watch marks one
    /// as read once it has handed it over.
    case unreadCoredump
    /// A file from the watch's own filesystem.
    case file(name: String)

    var command: UInt8 {
        switch self {
        case .coredump: 0x00
        case .file: 0x03
        case .unreadCoredump: 0x05
        }
    }
}

/// Pulling a whole object off the watch: a crash dump, or a file.
///
/// The watch answers with how many bytes there are and then sends them in
/// chunks, each saying where it belongs. Nothing marks the last one, so the end
/// is the byte count being reached.
public enum GetBytesCodec {
    public static var endpoint: UInt16 { 9_000 }

    static let objectInfoCommand: UInt8 = 0x01
    static let objectDataCommand: UInt8 = 0x02

    /// More than any watch could have to send: the largest flash a Pebble has
    /// is 32 MiB, and a coredump is a fraction of one. The size arrives as a
    /// 32-bit number and is believed before a byte of the object has, so a
    /// corrupt frame would otherwise have the app reserve four gigabytes.
    static let maximumObjectByteCount = 32 * 1_024 * 1_024

    public static func requestFrame(_ request: GetBytesRequest, transactionID: UInt8) -> PebbleProtocolFrame {
        var payload: [UInt8] = [request.command, transactionID]
        if case .file(let name) = request {
            let bytes = Array(name.utf8.prefix(Int(UInt8.max)))
            payload.append(UInt8(bytes.count))
            payload += bytes
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }
}

/// Reads an object as it arrives.
public struct GetBytesCollector: Sendable {
    private let transactionID: UInt8
    private var expectedByteCount: Int?
    private var bytes: [UInt8] = []

    public init(transactionID: UInt8) {
        self.transactionID = transactionID
    }

    /// Takes one frame, and returns the object once the last of it is in.
    ///
    /// A frame for another transaction is ignored rather than refused: an
    /// answer to a request that has already been given up on is not this
    /// caller's to complain about.
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
            // A watch with nothing to send says so by saying there is none of
            // it, and then sends no chunks at all.
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
    /// The watch said the object is bigger than any watch could hold, which
    /// means the frame is corrupt rather than that the object is real.
    case objectTooLarge(Int)
    /// One means the watch did not understand the request, two that it is
    /// already sending something, three that there is no such object, four
    /// that what it has is corrupt.
    case refused(UInt8)
}
