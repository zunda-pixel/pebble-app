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
    /// The promise to take the watch's own settings back. `prefs_sync.c` starts
    /// pushing the settings database the moment the phone reports it.
    case settingsSync = 23
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

    /// The firmware reads this claim once, while connecting, and then keeps whole
    /// features to itself unless the bit is there: it refuses a weather write from
    /// a phone that has not claimed the weather app, hides the Reminders app
    /// without the reminders bit, reads only the first three fields of a
    /// now-playing frame without the extended-music bit, and falls back to the
    /// legacy firmware-update path without the smooth-progress bit.
    /// `settingsSync` is claimed now that there is somewhere to put what it
    /// brings. It was deliberately absent while the inbound `BlobDB2` dispatch
    /// answered `default: break` to the settings database — claiming it then
    /// would have set the watch pushing records that came straight back
    /// refused. `handleBlobDB2` reads them now.
    public static var supportedCapabilities: Set<PhoneCapability> {
        [
            .appRunStateProtocol, .infiniteLogDump, .extendedMusicProtocol,
            .appMessage8k, .appDictation, .notificationFiltering, .unreadCoreDump,
            .weatherApp, .remindersApp, .smoothFirmwareInstallProgress,
            .settingsSync,
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
        // OS identifier in the low nibble plus the BTLE feature bit.
        payload.append(contentsOf: (operatingSystem.rawValue | 128).bigEndianBytes)
        payload.append(2)
        // The last official Pebble app version, 4.4.2.
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
