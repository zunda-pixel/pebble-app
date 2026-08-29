import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchVersionInformation: Equatable, Sendable {
    public var firmwareVersion: String
    public var serialNumber: String
    public var hardwarePlatform: UInt8
    /// Whether the watch booted the recovery firmware (PRF). Such a watch
    /// answers version and ping requests but rejects every other endpoint, so
    /// it can only be talked to for a firmware install.
    public var isRunningRecoveryFirmware: Bool = false
}

public enum WatchVersionCodec {
    public static var endpoint: UInt16 { 16 }

    public static func requestFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x00])
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> WatchVersionInformation {
        guard frame.endpoint == endpoint else {
            throw WatchVersionCodecError.unexpectedEndpoint
        }
        guard frame.payload.count >= 120 else {
            throw WatchVersionCodecError.truncatedResponse
        }
        guard frame.payload[0] == 0x01 else {
            throw WatchVersionCodecError.unexpectedMessage
        }

        return WatchVersionInformation(
            firmwareVersion: fixedString(frame.payload[5..<37]),
            serialNumber: fixedString(frame.payload[108..<120]),
            hardwarePlatform: frame.payload[46],
            isRunningRecoveryFirmware: frame.payload[45] != 0
        )
    }

    private static func fixedString(_ bytes: ArraySlice<UInt8>) -> String {
        let content = bytes.prefix { $0 != 0 }
        return String(decoding: content, as: UTF8.self)
    }
}

public enum WatchVersionCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case unexpectedMessage
    case truncatedResponse
}

public extension PebbleWatchModel {
    init?(hardwarePlatform: UInt8) {
        switch hardwarePlatform {
        case 15:
            self = .pebble2Duo
        case 13, 16, 17, 18, 243, 244, 247, 249:
            self = .pebbleTime2
        case 19, 20, 21:
            self = .pebbleRound2
        default:
            return nil
        }
    }
}
