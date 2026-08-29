import MemberwiseInit

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
    /// Whether the watch booted its recovery firmware. Such a watch rejects
    /// every endpoint except version and ping, so the companion app can only
    /// offer it a firmware install.
    public var isRunningRecoveryFirmware: Bool = false
    /// Which firmware slot is running on a dual-slot watch, or nil when it has
    /// only one. Firmware is installed into the other slot.
    public var runningFirmwareSlot: Int? = nil

    /// The slot a firmware update targets: the one that is not running.
    public var firmwareUpdateSlot: Int? {
        switch runningFirmwareSlot {
        case 0: 1
        case 1: 0
        default: nil
        }
    }
}
