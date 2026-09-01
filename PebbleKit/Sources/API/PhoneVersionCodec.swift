public enum PhoneCapability: Int, Equatable, Sendable, CaseIterable {
    case appRunStateProtocol = 0
    case infiniteLogDump = 1
    case extendedMusicProtocol = 2
    case twoWayDismissal = 3
    case localization = 4
    case appMessage8k = 5
    case healthInsights = 6
    case appDictation = 7
    case sendTextApp = 8
    case notificationFiltering = 9
    case unreadCoreDump = 10
    case weatherApp = 11
}

public enum PhoneOperatingSystem: UInt32, Equatable, Sendable {
    case unknown = 0
    case iOS = 1
    case android = 2
    case macOS = 3
    case linux = 4
    case windows = 5
}

public enum PhoneVersionCodec {
    public static var endpoint: UInt16 { 17 }

    /// The capabilities this companion app actually implements.
    ///
    /// The weather bit is not decoration: the firmware refuses a write to the
    /// weather database from a phone that has not claimed it
    /// (`weather_service_supported_by_phone`), and it reads the claim from the
    /// answer given here, once, while connecting.
    ///
    /// The send-text bit is deliberately absent: the watch hides that app from
    /// a phone that has not claimed it, and a phone that cannot send a message
    /// has no business offering it.
    public static var supportedCapabilities: Set<PhoneCapability> {
        [
            .appRunStateProtocol, .infiniteLogDump, .appMessage8k, .appDictation,
            .notificationFiltering, .weatherApp,
        ]
    }

    public static func isRequest(_ frame: PebbleProtocolFrame) -> Bool {
        frame.endpoint == endpoint && frame.payload.first == 0x00
    }

    public static func responseFrame(
        operatingSystem: PhoneOperatingSystem,
        capabilities: Set<PhoneCapability> = supportedCapabilities
    ) -> PebbleProtocolFrame {
        var payload: [UInt8] = [0x01]
        payload.append(contentsOf: UInt32.max.bigEndianBytes)
        payload.append(contentsOf: UInt32(0).bigEndianBytes)
        // Platform flags: OS identifier in the low nibble plus the BTLE feature bit.
        payload.append(contentsOf: (operatingSystem.rawValue | 128).bigEndianBytes)
        payload.append(2)
        // Advertise compatibility with the last official Pebble app version, 4.4.2.
        payload.append(contentsOf: [4, 4, 2])
        payload.append(contentsOf: capabilityBytes(capabilities))
        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }

    static func capabilityBytes(_ capabilities: Set<PhoneCapability>) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 8)
        for capability in capabilities {
            bytes[capability.rawValue / 8] |= 1 << (capability.rawValue % 8)
        }
        return bytes
    }
}
