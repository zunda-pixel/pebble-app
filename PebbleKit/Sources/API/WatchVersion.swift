import Algorithms
import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchVersionInformation: Equatable, Sendable {
    public var firmwareVersion: String
    public var serialNumber: String
    public var hardwarePlatform: UInt8
    /// A watch in recovery firmware (PRF) answers version and ping requests and
    /// rejects every other endpoint.
    public var isRunningRecoveryFirmware: Bool = false
    /// Nil on a watch with a single slot. An update goes to the other slot.
    public var runningFirmwareSlot: Int? = nil
    /// As the firmware spells it — `en_US`, `fr_FR`. Empty on a watch that has
    /// never been given a pack.
    public var languageLocale: String = ""
    public var languageVersion: UInt16 = 0
    /// Older firmware sends a shorter response and no capabilities at all, which
    /// reads as none.
    public var capabilities: UInt64 = 0

    public var supportsLanguagePacks: Bool {
        WatchCapability.languagePack.isSet(in: capabilities)
    }

    public var supportsWeatherApp: Bool {
        WatchCapability.weatherApp.isSet(in: capabilities)
    }

    public var board: PebbleWatchBoard? {
        PebbleWatchBoard(hardwarePlatform: hardwarePlatform)
    }
}

/// In the order the firmware declares them.
public enum WatchCapability: UInt64, Sendable {
    case runState = 0
    case infiniteLogDumping = 1
    case extendedMusicService = 2
    case extendedNotificationService = 3
    case languagePack = 4
    case appMessage8k = 5
    case activityInsights = 6
    case voiceAPI = 7
    case sendText = 8
    case notificationFiltering = 9
    case unreadCoredump = 10
    case weatherApp = 11
    case remindersApp = 12
    case workoutApp = 13
    case smoothFirmwareInstallProgress = 14
    case customVibePattern = 15

    public func isSet(in capabilities: UInt64) -> Bool {
        capabilities & (1 << rawValue) != 0
    }
}

enum FirmwareFlag: UInt8 {
    case recovery = 0
    case bluetooth = 1
    case dualSlot = 2
    case slot0 = 3

    func isSet(in flags: UInt8) -> Bool {
        flags & (1 << rawValue) != 0
    }
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

        // Timestamp, version tag, git hash, a flags byte, the hardware platform and
        // a metadata version.
        let flags = frame.payload[45]
        let slot: Int? = FirmwareFlag.dualSlot.isSet(in: flags)
            ? (FirmwareFlag.slot0.isSet(in: flags) ? 0 : 1)
            : nil
        // After the two firmware metadata blocks, the bootloader timestamp, board,
        // serial, Bluetooth address and resource version.
        return WatchVersionInformation(
            firmwareVersion: fixedString(frame.payload[5..<37]),
            serialNumber: fixedString(frame.payload[108..<120]),
            hardwarePlatform: frame.payload[46],
            isRunningRecoveryFirmware: FirmwareFlag.recovery.isSet(in: flags),
            runningFirmwareSlot: slot,
            languageLocale: frame.payload.count >= 140 ? fixedString(frame.payload[134..<140]) : "",
            languageVersion: frame.payload.count >= 142
                ? UInt16(frame.payload[140]) << 8 | UInt16(frame.payload[141])
                : 0,
            capabilities: frame.payload.count >= 150
                ? capabilityFlags(frame.payload[142..<150])
                : 0
        )
    }

    // A packed struct of single-bit fields, so it arrives least significant byte
    // first whatever the rest of the message does.
    private static func capabilityFlags(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.indexed().reduce(into: UInt64(0)) { flags, pair in
            let (index, byte) = pair
            flags |= UInt64(byte) << (UInt64(index - bytes.startIndex) * 8)
        }
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
