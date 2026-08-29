/// Watch-side reset commands. Every one of them is fire-and-forget: the watch
/// reboots (or wipes itself) instead of acknowledging the request, so the link
/// drops right after the frame is written.
public enum PebbleResetKind: UInt8, Equatable, Sendable, CaseIterable {
    /// Reboots the watch, keeping apps and settings.
    case restart = 0x00
    /// Reboots into the recovery firmware (PRF).
    case recoveryFirmware = 0xFF
    /// Erases the watch and restores factory defaults.
    case factoryReset = 0xFE
}

public enum ResetCodec {
    public static var endpoint: UInt16 { 2_003 }

    public static func frame(_ kind: PebbleResetKind) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [kind.rawValue])
    }
}
