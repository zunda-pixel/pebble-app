import Algorithms
import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchVersionInformation: Equatable, Hashable, Sendable {
    /// Nil where the watch's field was empty. Optional so that `ConnectedWatch`
    /// can hand this straight out without asking twice.
    public var firmwareVersion: String?
    /// Nil where the watch has none written — every watch in the emulator,
    /// measured: its OTP is unprogrammed and the field arrives as zeroes.
    public var serialNumber: String?
    /// What was burned into the watch's one-time-programmable memory at the
    /// factory — `V2R2` and the like. `mfg_get_hw_version` in PebbleOS's
    /// `src/fw/mfg/mfg_serials.c` reads it from the newest locked OTP slot.
    ///
    /// Not the board. That is `board` below, and it comes from the platform
    /// byte: this field is nine bytes wide, which `obelix_pvt` does not fit in,
    /// and a watch off the bench has never had it written.
    ///
    /// Nil when the watch did not say — which covers an unprogrammed watch,
    /// where the firmware sends its `XXXXXXXX` placeholder, and a field of
    /// zeroes.
    ///
    /// Optional rather than empty-for-absent, unlike `languageLocale` above:
    /// this is passed along four types to reach a screen, and "" would have to
    /// be recognised as absence at every hop or it would win over a remembered
    /// revision the moment a watch without one connected.
    public var hardwareRevision: String? = nil
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

    public var board: WatchBoard? {
        WatchBoard(hardwarePlatform: hardwarePlatform)
    }

    /// One line about the watch, for the connection log and the diagnostic
    /// report.
    ///
    /// Shared so that both transports say the same thing about the same watch.
    /// The Bluetooth one wrote a shorter version of this and the emulator's
    /// wrote nothing at all, which is how a watch reaching the app with no
    /// board and no capabilities went unremarked.
    ///
    /// The capabilities are named rather than left as a number, because the
    /// question a reader has is which feature the watch will refuse — and an
    /// unrecognised board is printed as its platform byte, since that is the
    /// one thing the watch definitely did say.
    public var diagnosticSummary: String {
        var parts = [
            "firmware \(firmwareVersion ?? "unknown")",
            "on \(board?.rawValue ?? "platform \(hardwarePlatform)")",
        ]
        if let hardwareRevision { parts.append("rev \(hardwareRevision)") }
        if let slot = runningFirmwareSlot { parts.append("slot \(slot)") }
        if !languageLocale.isEmpty { parts.append("lang \(languageLocale) v\(languageVersion)") }
        let named = WatchCapability.allCases.filter { $0.isSet(in: capabilities) }
        parts.append(named.isEmpty
            ? "no capabilities"
            : "capabilities \(named.map(\.name).joined(separator: ","))")
        return parts.joined(separator: " / ")
    }
}

/// In the order the firmware declares them.
public enum WatchCapability: UInt64, CaseIterable, Sendable {
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
    /// Bit 23, and the one the watch does not set in its own response: it is
    /// the phone's claim, read by `settings_blob_db_phone_supports_sync`. Named
    /// here so the connection log can say whether the phone made it.
    case settingsSync = 23

    public func isSet(in capabilities: UInt64) -> Bool {
        capabilities & (1 << rawValue) != 0
    }

    /// For the connection log. Spelled out rather than reflected, so renaming a
    /// case does not silently rename what a saved diagnostic report says.
    public var name: String {
        switch self {
        case .runState: "runState"
        case .infiniteLogDumping: "infiniteLogDumping"
        case .extendedMusicService: "extendedMusicService"
        case .extendedNotificationService: "extendedNotificationService"
        case .languagePack: "languagePack"
        case .appMessage8k: "appMessage8k"
        case .activityInsights: "activityInsights"
        case .voiceAPI: "voiceAPI"
        case .sendText: "sendText"
        case .notificationFiltering: "notificationFiltering"
        case .unreadCoredump: "unreadCoredump"
        case .weatherApp: "weatherApp"
        case .remindersApp: "remindersApp"
        case .workoutApp: "workoutApp"
        case .smoothFirmwareInstallProgress: "smoothFirmwareInstallProgress"
        case .customVibePattern: "customVibePattern"
        case .settingsSync: "settingsSync"
        }
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
        // After the two firmware metadata blocks, the bootloader timestamp, the
        // manufacturing hardware revision, the serial, the Bluetooth address and
        // the resource version.
        //
        // The offsets come from `struct VersionsMessage` in PebbleOS's
        // `src/fw/kernel/system_versions.c` and `sizeof(FirmwareMetadata)` = 47
        // (4 + 32 + 8 + 1 + 1 + 1) from `include/pebbleos/firmware_metadata.h`:
        // command 0, running metadata 1, recovery metadata 48, bootloader
        // timestamp 95, hw_version 99 for `MFG_HW_VERSION_SIZE` = 9, serial 108
        // for 12, address 120 for 6. That is 126 in all, which is the length
        // the firmware's own `_Static_assert` calls the pre-v1.5 version info.
        return WatchVersionInformation(
            firmwareVersion: fixedString(frame.payload[5..<37]).nilWhenEmpty,
            serialNumber: fixedString(frame.payload[108..<120]).nilWhenEmpty,
            hardwareRevision: manufacturingRevision(frame.payload[99..<108]),
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

    /// The hardware revision, or nil when the watch has none to give.
    ///
    /// `mfg_get_hw_version` returns its `DUMMY_HWVER` — the literal string
    /// `XXXXXXXX` — when no OTP slot has been locked, which is every watch that
    /// has not been through the factory step that writes it. Showing that to a
    /// reader as a hardware revision would be presenting a placeholder as a
    /// fact, so it reads as absent, the same as a field of zeroes.
    private static func manufacturingRevision(_ bytes: ArraySlice<UInt8>) -> String? {
        let revision = fixedString(bytes)
        guard !revision.isEmpty, !revision.allSatisfy({ $0 == "X" }) else { return nil }
        return revision
    }
}

public enum WatchVersionCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case unexpectedMessage
    case truncatedResponse
}
