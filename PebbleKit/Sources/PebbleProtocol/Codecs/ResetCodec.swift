/// Fire-and-forget: the watch reboots, or wipes itself, instead of
/// acknowledging, so the link drops without an answer.
public enum PebbleResetKind: UInt8, Equatable, Sendable, CaseIterable {
    case restart = 0x00
    case recoveryFirmware = 0xFF
    case factoryReset = 0xFE
}

public enum ResetCodec {
    public static var endpoint: UInt16 { 2_003 }

    public static func frame(_ kind: PebbleResetKind) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [kind.rawValue])
    }
}
