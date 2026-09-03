import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleProtocolFrame: Equatable, Sendable {
    public var endpoint: UInt16
    public var payload: [UInt8]

    /// Where the firmware answers for an endpoint rather than from it: a reason
    /// and the endpoint it is refusing. A watch in recovery firmware answers
    /// nearly everything here.
    public static var metaEndpoint: UInt16 { 0 }

    /// The endpoint a refusal on ``metaEndpoint`` was refusing, which is how a
    /// watch says it does not implement what it was asked for.
    public var rejectedEndpoint: UInt16? {
        guard endpoint == Self.metaEndpoint,
              payload.count >= 3,
              payload[0] == 0xDC || payload[0] == 0xDD else {
            return nil
        }
        return UInt16(payload[1]) << 8 | UInt16(payload[2])
    }

    public func encoded() throws -> [UInt8] {
        guard !payload.isEmpty else {
            throw PebbleProtocolFrameError.emptyPayload
        }
        guard payload.count <= Int(UInt16.max) else {
            throw PebbleProtocolFrameError.payloadTooLarge
        }

        let length = UInt16(payload.count)
        return [
            UInt8(length >> 8),
            UInt8(length & 0xFF),
            UInt8(endpoint >> 8),
            UInt8(endpoint & 0xFF),
        ] + payload
    }
}

/// The frames and the failure travel together: the watch packs frames for
/// unrelated endpoints into a single delivery, so a length prefix that cannot
/// begin a frame must not take the frames decoded before it down with it.
@MemberwiseInit(.public)
public struct PebbleProtocolFrameBatch: Equatable, Sendable {
    public var frames: [PebbleProtocolFrame] = []
    public var failure: PebbleProtocolFrameError? = nil
}

@MemberwiseInit(.public)
public struct PebbleProtocolFrameDecoder: Sendable {
    @Init(.ignore) private var buffer: [UInt8] = []

    public mutating func append(_ bytes: [UInt8]) -> PebbleProtocolFrameBatch {
        buffer.append(contentsOf: bytes)
        var frames: [PebbleProtocolFrame] = []

        while buffer.count >= 4 {
            let payloadLength = Int(UInt16(buffer[0]) << 8 | UInt16(buffer[1]))
            guard payloadLength > 0 else {
                // A zero length says the stream is no longer on a frame boundary. Drop the
                // prefix so the next chunk can resynchronise.
                buffer.removeFirst(4)
                return PebbleProtocolFrameBatch(frames: frames, failure: .emptyPayload)
            }

            let frameLength = payloadLength + 4
            guard buffer.count >= frameLength else {
                break
            }

            let endpoint = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
            let payload = Array(buffer[4..<frameLength])
            frames.append(PebbleProtocolFrame(endpoint: endpoint, payload: payload))
            buffer.removeFirst(frameLength)
        }

        return PebbleProtocolFrameBatch(frames: frames)
    }
}

public enum PebbleProtocolFrameError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
}
