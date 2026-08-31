import Algorithms
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
    /// Which of a dual-slot watch's two firmware slots is running, or nil on a
    /// watch with a single slot. An update goes to the other slot.
    public var runningFirmwareSlot: Int? = nil
    /// The locale of the language pack the watch is running, as the firmware
    /// spells it — `en_US`, `fr_FR`. Empty on a watch that has never been given
    /// a pack, which is how the built-in English is reported.
    public var languageLocale: String = ""
    /// The version of that pack, counted by whoever built it. Zero alongside an
    /// empty locale means no pack is installed.
    public var languageVersion: UInt16 = 0
    /// What the firmware says it can do, as a bitfield. Older firmware sends a
    /// shorter response and no capabilities at all, which reads as none.
    public var capabilities: UInt64 = 0

    /// Whether the watch takes language packs at all.
    public var supportsLanguagePacks: Bool {
        WatchCapability.languagePack.isSet(in: capabilities)
    }

    /// Whether the watch has the weather app the phone writes forecasts for.
    public var supportsWeatherApp: Bool {
        WatchCapability.weatherApp.isSet(in: capabilities)
    }

    /// The board revision firmware packages are named after.
    public var board: PebbleWatchBoard? {
        PebbleWatchBoard(hardwarePlatform: hardwarePlatform)
    }
}

/// The bits of the capability field the watch sends with its version, in the
/// order the firmware declares them.
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

/// The bits of the running firmware's flags byte.
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

        // The running firmware's metadata is timestamp, version tag, git hash,
        // a flags byte, the hardware platform and a metadata version.
        let flags = frame.payload[45]
        let slot: Int? = FirmwareFlag.dualSlot.isSet(in: flags)
            ? (FirmwareFlag.slot0.isSet(in: flags) ? 0 : 1)
            : nil
        // The locale, its version and the capabilities come after the two
        // firmware metadata blocks, the bootloader timestamp, board, serial,
        // Bluetooth address and resource version. Firmware old enough to stop
        // before them simply says nothing about any of it.
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

    /// The capability bitfield is a packed struct of single-bit fields, so it
    /// arrives least significant byte first whatever the rest of the message
    /// does.
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
