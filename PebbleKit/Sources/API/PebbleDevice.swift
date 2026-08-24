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
}
