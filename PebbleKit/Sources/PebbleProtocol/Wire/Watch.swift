import MemberwiseInit

/// Several revisions share a watch model — a Pebble Time 2 can be any of the
/// obelix boards — and firmware is built per board.
public enum WatchBoard: String, CaseIterable, Codable, Sendable {
    case asterix
    case obelixEVT = "obelix_evt"
    case obelixDVT = "obelix_dvt"
    case obelixPVT = "obelix_pvt"
    case obelixBigboard = "obelix_bb"
    case obelixBigboard2 = "obelix_bb2"
    case getafixEVT = "getafix_evt"
    case getafixDVT = "getafix_dvt"
    case getafixDVT2 = "getafix_dvt2"
    case robertEVT = "robert_evt"
    case robertBigboard = "robert_bb"
    case robertBigboard2 = "robert_bb2"
    /// The three boards PebbleOS builds for the emulator, named as its own
    /// `boards/` directories are. They were missing, so a watch in QEMU had no
    /// board at all — which is the only thing the firmware screen goes on, and
    /// left the diagnostic log writing "platform 245" for want of a name.
    ///
    /// They have no release asset: `build-qemu.yml` is a separate workflow from
    /// the `build-firmware.yml` that publishes `normal_<board>_<version>.pbz`.
    /// So the firmware catalogue answers `noFirmwareForBoard`, which is a
    /// sentence, where a nil board was silence.
    case qemuEmery = "qemu_emery"
    case qemuFlint = "qemu_flint"
    case qemuGabbro = "qemu_gabbro"

    /// The platform byte the firmware puts in its version response.
    ///
    /// These are `FirmwareMetadataPlatform` in PebbleOS's
    /// `include/pebbleos/firmware_metadata.h`, and only the ones that file
    /// still has a `FIRMWARE_METADATA_HW_PLATFORM` mapping for are here — the
    /// classic Pebbles are in that enum too, and this app cannot drive them.
    public init?(hardwarePlatform: UInt8) {
        switch hardwarePlatform {
        case 13: self = .robertEVT
        case 15: self = .asterix
        case 16: self = .obelixEVT
        case 17: self = .obelixDVT
        case 18: self = .obelixPVT
        case 19: self = .getafixEVT
        case 20: self = .getafixDVT
        case 21: self = .getafixDVT2
        case 242: self = .qemuGabbro
        case 243: self = .obelixBigboard2
        case 244: self = .obelixBigboard
        case 245: self = .qemuEmery
        case 246: self = .qemuFlint
        case 247: self = .robertBigboard2
        case 249: self = .robertBigboard
        default: return nil
        }
    }
}

public extension WatchBoard {
    /// What this board was built with, read out of `boards/<name>/defconfig`
    /// in PebbleOS. These gate settings rows: a switch for hardware the watch
    /// does not have is a row that does nothing in front of the reader.
    ///
    /// Per board and not per model, because the emulator differs from the
    /// hardware it stands in for: `qemu_emery` is a Pebble Time 2 to
    /// `WatchModel`, but its defconfig has no `CONFIG_DYNAMIC_BACKLIGHT`
    /// where the real board's does — gating by model would offer the emulated
    /// watch a row its whitelist refuses.
    ///
    /// The robert boards answer false throughout: they have no `boards/`
    /// directory in this PebbleOS tree, so what they were built with cannot be
    /// read, and a row that might do nothing is worse than no row.

    /// `CONFIG_TOUCH`. Gates the touch-wake row; the `lightTouch` pref itself
    /// exists on every board and is compared against presets everywhere.
    var hasTouch: Bool {
        switch self {
        case .getafixEVT, .getafixDVT, .getafixDVT2,
             .obelixEVT, .obelixDVT, .obelixPVT, .obelixBigboard, .obelixBigboard2,
             .qemuEmery, .qemuGabbro:
            true
        default:
            false
        }
    }

    /// `CONFIG_DYNAMIC_BACKLIGHT`. Unlike the other two, this one gates the
    /// *whitelist* itself (`settings_blob_db.c`): a board without it answers
    /// a `lightDynamicMode` write with `E_INVALID_OPERATION`.
    var hasDynamicBacklight: Bool {
        switch self {
        case .getafixEVT, .getafixDVT, .getafixDVT2,
             .obelixEVT, .obelixDVT, .obelixPVT, .obelixBigboard, .obelixBigboard2:
            true
        default:
            false
        }
    }

    /// `CONFIG_BACKLIGHT_HAS_COLOR`, selected by the LED driver: obelix's
    /// AW2016 and the emulator's `BACKLIGHT_QEMU_COLOR` have colour; getafix's
    /// AW9364E and asterix's PWM do not. Also whitelist-gating, for
    /// `lightColor`.
    var hasColorBacklight: Bool {
        switch self {
        case .obelixEVT, .obelixDVT, .obelixPVT, .obelixBigboard, .obelixBigboard2,
             .qemuEmery:
            true
        default:
            false
        }
    }
}

public enum WatchModel: String, CaseIterable, Codable, Sendable {
    case pebble2Duo = "FLINT"
    case pebbleTime2 = "EMERY"
    case pebbleRound2 = "GABBRO"

    public var displayName: String {
        switch self {
        case .pebble2Duo:
            "Pebble 2 Duo"
        case .pebbleTime2:
            "Pebble Time 2"
        case .pebbleRound2:
            "Pebble Round 2"
        }
    }
}

@MemberwiseInit(.public)
public struct DiscoveredWatch: Identifiable, Hashable, Sendable {
    public var id: WatchID
    public var name: String
    public var model: WatchModel
    public var signalStrength: Int
}

/// A watch the app is talking to.
///
/// Three sources meet here and only three: the advertisement gives the name,
/// the battery service gives the level, and the version response gives
/// everything else. That last one is held whole rather than unpacked.
///
/// It used to be unpacked — eight of these fields were copies of
/// `WatchVersionInformation`, written across one by one, and `board` was a
/// ninth derived from it. Two things went wrong because of that.
/// `QEMUWatchClient` built one of these from four fields and dropped the rest,
/// so a watch in the emulator arrived with no board and no capabilities and
/// nothing could catch it. And adding `hardwareRevision` took four edits —
/// here, the version response, and both transports — because each field had to
/// be carried by hand.
///
/// The version-derived properties below are computed, so they cannot disagree
/// with the response they came from. That is the point: the emulator's board
/// was not wrong, it was *stored* as nil while the version knew better.
@MemberwiseInit(.public)
public struct ConnectedWatch: Identifiable, Hashable, Sendable {
    public var id: WatchID
    /// From the advertisement, not the version response.
    public var name: String
    /// Which watch this is.
    ///
    /// Stored rather than computed, because `WatchModel(hardwarePlatform:)`
    /// answers nil for a platform this app does not know and the discovered
    /// watch's own model is the better guess then. The transports resolve that.
    public var model: WatchModel
    /// From the battery service, not the version response.
    public var batteryLevel: Int?
    /// What the watch said about itself when it connected.
    public var version: WatchVersionInformation

    public var firmwareVersion: String? { version.firmwareVersion }
    public var serialNumber: String? { version.serialNumber }
    /// The revision burned in at the factory, beside the serial it sits beside
    /// in the version response. Nil on a watch that never had one written.
    public var hardwareRevision: String? { version.hardwareRevision }
    /// A watch in recovery firmware rejects every endpoint except version and
    /// ping, so it can only be offered a firmware install.
    public var isRunningRecoveryFirmware: Bool { version.isRunningRecoveryFirmware }
    /// Nil when the watch has only one. Firmware is installed into the other.
    public var runningFirmwareSlot: Int? { version.runningFirmwareSlot }
    public var board: WatchBoard? { version.board }
    /// Empty when the watch runs the firmware's built-in English.
    public var languageLocale: String { version.languageLocale }
    public var languageVersion: UInt16 { version.languageVersion }
    public var capabilities: UInt64 { version.capabilities }

    public var supportsLanguagePacks: Bool {
        WatchCapability.languagePack.isSet(in: capabilities)
    }

    public var supportsWeatherApp: Bool {
        WatchCapability.weatherApp.isSet(in: capabilities)
    }

    public var supportsCustomVibePatterns: Bool {
        WatchCapability.customVibePattern.isSet(in: capabilities)
    }

    public var supportsNotificationFiltering: Bool {
        WatchCapability.notificationFiltering.isSet(in: capabilities)
    }

    public var firmwareUpdateSlot: Int? {
        switch runningFirmwareSlot {
        case 0: 1
        case 1: 0
        default: nil
        }
    }
}

/// A watch this phone is bonded to that the app has no record of. It cannot be
/// scanned for — a bonded Pebble does not advertise — so it is noticed only
/// when it subscribes to the phone's protocol service.
public struct UnknownBondedWatch: Identifiable, Hashable, Sendable {
    public var id: WatchID
    public var name: String

    public init(id: WatchID, name: String) {
        self.id = id
        self.name = name
    }
}
