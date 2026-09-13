import Foundation
import MemberwiseInit

public enum AudioStreamMessage: Equatable, Sendable {
    /// The encoded frames a message carried, each one already cut to the length
    /// the watch gave it. A decoder is handed whole frames or nothing.
    case data(sessionID: UInt16, frames: [[UInt8]])
    case stop(sessionID: UInt16)
}

public enum AudioStreamCodec {
    public static var endpoint: UInt16 { 10_000 }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> AudioStreamMessage {
        guard frame.endpoint == endpoint else {
            throw VoiceCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 3 else {
            throw VoiceCodecError.invalidPayload
        }
        let sessionID = UInt16(frame.payload[1]) | UInt16(frame.payload[2]) << 8
        switch frame.payload[0] {
        case 0x02:
            guard frame.payload.count >= 4 else {
                throw VoiceCodecError.invalidPayload
            }
            // The watch sends one frame per message today, but the count byte is
            // on the wire and a run of them is a legal message.
            var frames: [[UInt8]] = []
            var offset = 4
            for _ in 0..<Int(frame.payload[3]) {
                guard offset < frame.payload.count else {
                    throw VoiceCodecError.invalidPayload
                }
                let length = Int(frame.payload[offset])
                offset += 1
                guard offset + length <= frame.payload.count else {
                    throw VoiceCodecError.invalidPayload
                }
                frames.append(Array(frame.payload[offset..<offset + length]))
                offset += length
            }
            return .data(sessionID: sessionID, frames: frames)
        case 0x03:
            return .stop(sessionID: sessionID)
        default:
            throw VoiceCodecError.unknownCommand
        }
    }

    public static func stopFrame(sessionID: UInt16) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [0x03, UInt8(sessionID & 0xFF), UInt8(sessionID >> 8)]
        )
    }
}
