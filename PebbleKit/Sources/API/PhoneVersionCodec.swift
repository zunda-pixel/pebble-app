/// The bits of `PebbleProtocolCapabilities`, in the firmware's own order.
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
    case remindersApp = 12
    case workoutApp = 13
    case smoothFirmwareInstallProgress = 14
    case customVibrationPattern = 15
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
    /// These are not decoration. The firmware reads the claim once, while
    /// connecting, and then keeps whole features to itself unless it is there:
    /// it refuses a write to the weather database from a phone that has not
    /// claimed the weather app (`weather_service_supported_by_phone`), hides
    /// the Reminders app from the launcher without the reminders bit
    /// (`reminder_app_get_info`), reads only the first three fields of a
    /// now-playing frame and reports no music capabilities at all without the
    /// extended-music bit (`endpoint.c`), and falls back to the legacy
    /// firmware-update path — ignoring the byte counts we send it — without the
    /// smooth-progress bit (`system_message.c`).
    ///
    /// The send-text bit is deliberately absent: the watch hides that app from
    /// a phone that has not claimed it, and a phone that cannot send a message
    /// has no business offering it. So are the language-pack, health-insight,
    /// workout, custom-vibration and settings-sync bits, each of which stands
    /// for a conversation this app does not yet hold up its end of.
    public static var supportedCapabilities: Set<PhoneCapability> {
        [
            .appRunStateProtocol, .infiniteLogDump, .extendedMusicProtocol,
            .appMessage8k, .appDictation, .notificationFiltering, .unreadCoreDump,
            .weatherApp, .remindersApp, .smoothFirmwareInstallProgress,
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
