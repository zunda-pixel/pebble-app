import MemberwiseInit

/// Several revisions share a watch model — a Pebble Time 2 can be any of the
/// obelix boards — and firmware is built per board.
public enum PebbleWatchBoard: String, CaseIterable, Codable, Sendable {
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
        case 243: self = .obelixBigboard2
        case 244: self = .obelixBigboard
        case 247: self = .robertBigboard2
        case 249: self = .robertBigboard
        default: return nil
        }
    }
}

public enum PebbleWatchModel: String, CaseIterable, Codable, Sendable {
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
public struct DiscoveredPebble: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var model: PebbleWatchModel
    public var signalStrength: Int
}

@MemberwiseInit(.public)
public struct PebbleDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var model: PebbleWatchModel
    public var firmwareVersion: String?
    public var batteryLevel: Int?
    public var serialNumber: String? = nil
    /// A watch in recovery firmware rejects every endpoint except version and
    /// ping, so it can only be offered a firmware install.
    public var isRunningRecoveryFirmware: Bool = false
    /// Nil when the watch has only one. Firmware is installed into the other.
    public var runningFirmwareSlot: Int? = nil
    public var board: PebbleWatchBoard? = nil
    /// Empty when the watch runs the firmware's built-in English.
    public var languageLocale: String = ""
    public var languageVersion: UInt16 = 0
    public var capabilities: UInt64 = 0

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
