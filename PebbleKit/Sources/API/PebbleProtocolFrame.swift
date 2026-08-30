import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleProtocolFrame: Equatable, Sendable {
    public var endpoint: UInt16
    public var payload: [UInt8]

    /// The endpoint this frame refuses, when it is the watch saying it does not
    /// implement one. Firmware answers on endpoint 0 with `DC` and the endpoint
    /// that was addressed; recovery firmware refuses nearly everything this
    /// way, so a refusal is often the only reply a request gets.
    public var rejectedEndpoint: UInt16? {
        guard endpoint == 0, payload.count >= 3, payload[0] == 0xDC else {
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

@MemberwiseInit(.public)
public struct PebbleProtocolFrameDecoder: Sendable {
    @Init(.ignore) private var buffer: [UInt8] = []

    public mutating func append(_ bytes: [UInt8]) throws -> [PebbleProtocolFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [PebbleProtocolFrame] = []

        while buffer.count >= 4 {
            let payloadLength = Int(UInt16(buffer[0]) << 8 | UInt16(buffer[1]))
            guard payloadLength > 0 else {
                buffer.removeFirst(4)
                throw PebbleProtocolFrameError.emptyPayload
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

        return frames
    }
}

public enum PebbleProtocolFrameError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge
}
