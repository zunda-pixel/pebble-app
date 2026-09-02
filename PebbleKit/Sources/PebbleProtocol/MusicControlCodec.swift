import Foundation
import MemberwiseInit

public enum MusicAction: UInt8, Equatable, Sendable, CaseIterable {
    case playPause = 0x01
    case pause = 0x02
    case play = 0x03
    case nextTrack = 0x04
    case previousTrack = 0x05
    case volumeUp = 0x06
    case volumeDown = 0x07
}

public enum MusicControlMessage: Equatable, Sendable {
    case action(MusicAction)
    case updateRequested
}

@MemberwiseInit(.public)
public struct MusicNowPlaying: Equatable, Sendable {
    public var artist: String = ""
    public var album: String = ""
    public var title: String = ""
    public var durationMilliseconds: UInt32? = nil
    public var trackCount: UInt32? = nil
    public var trackNumber: UInt32? = nil
}

public enum MusicPlaybackState: UInt8, Equatable, Sendable {
    case paused = 0x00
    case playing = 0x01
    case rewinding = 0x02
    case fastForwarding = 0x03
    case unknown = 0x04
}

public enum MusicShuffleState: UInt8, Equatable, Sendable {
    case unknown = 0x00
    case off = 0x01
    case on = 0x02
}

public enum MusicRepeatState: UInt8, Equatable, Sendable {
    case unknown = 0x00
    case off = 0x01
    case one = 0x02
    case all = 0x03
}

@MemberwiseInit(.public)
public struct MusicPlaybackStatus: Equatable, Sendable {
    public var state: MusicPlaybackState = .paused
    public var positionMilliseconds: UInt32 = 0
    public var playRatePercent: UInt32 = 0
    public var shuffle: MusicShuffleState = .off
    public var repeatState: MusicRepeatState = .off
    public var skipSeeksWithinTrack: Bool = false
}

public enum MusicControlCodec {
    public static var endpoint: UInt16 { 32 }

    // The watch's string fields carry a single-byte length prefix; the reference
    // implementation also caps display strings at 64 characters before encoding.
    static let maximumTextLength = 64

    public static func decode(_ frame: PebbleProtocolFrame) throws -> MusicControlMessage {
        guard frame.endpoint == endpoint else {
            throw MusicControlCodecError.unexpectedEndpoint
        }
        guard let command = frame.payload.first else {
            throw MusicControlCodecError.invalidPayload
        }
        if command == 0x08 {
            return .updateRequested
        }
        guard let action = MusicAction(rawValue: command) else {
            throw MusicControlCodecError.unknownCommand
        }
        return .action(action)
    }

    public static func nowPlayingFrame(_ nowPlaying: MusicNowPlaying) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x10]
        payload.append(contentsOf: pascalString(nowPlaying.artist))
        payload.append(contentsOf: pascalString(nowPlaying.album))
        payload.append(contentsOf: pascalString(nowPlaying.title))
        // Optional trailing fields must be truncated front-to-back: a later field
        // may only be present when every earlier one is.
        if let duration = nowPlaying.durationMilliseconds {
            payload.append(contentsOf: duration.littleEndianBytes)
            if let count = nowPlaying.trackCount {
                payload.append(contentsOf: count.littleEndianBytes)
                if let number = nowPlaying.trackNumber {
                    payload.append(contentsOf: number.littleEndianBytes)
                }
            }
        }
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func playbackStatusFrame(_ status: MusicPlaybackStatus) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x11, status.state.rawValue]
        payload.append(contentsOf: status.positionMilliseconds.littleEndianBytes)
        payload.append(contentsOf: status.playRatePercent.littleEndianBytes)
        payload.append(status.shuffle.rawValue)
        payload.append(status.repeatState.rawValue)
        payload.append(status.skipSeeksWithinTrack ? 1 : 0)
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    public static func volumeFrame(percent: UInt8) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x12, min(percent, 100)])
    }

    public static func playerInfoFrame(package: String, name: String) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x13]
        payload.append(contentsOf: pascalString(package))
        payload.append(contentsOf: pascalString(name))
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    static func pascalString(_ value: String) -> [UInt8] {
        var bytes = Array(String(value.prefix(maximumTextLength)).utf8)
        if bytes.count > 255 {
            bytes = Array(bytes.prefix(255))
            while !bytes.isEmpty, String(decoding: bytes, as: UTF8.self).hasSuffix("\u{FFFD}") {
                bytes.removeLast()
            }
        }
        return [UInt8(bytes.count)] + bytes
    }
}

public enum MusicControlCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case unknownCommand
}
