import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchVersionInformation: Equatable, Sendable {
    public var firmwareVersion: String
    public var serialNumber: String
    public var hardwarePlatform: UInt8
    /// Whether the watch booted the recovery firmware (PRF). Such a watch
    /// answers version and ping requests but rejects every other endpoint, so
    /// it can only be talked to for a firmware install.
    public var isRunningRecoveryFirmware: Bool = false
    /// Which of a dual-slot watch's two firmware slots is running, or nil on a
    /// watch with a single slot. An update goes to the other slot.
    public var runningFirmwareSlot: Int? = nil
}

/// The bits of the running firmware's flags byte.
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

        // The running firmware's metadata is timestamp, version tag, git hash,
        // a flags byte, the hardware platform and a metadata version.
        let flags = frame.payload[45]
        let slot: Int? = FirmwareFlag.dualSlot.isSet(in: flags)
            ? (FirmwareFlag.slot0.isSet(in: flags) ? 0 : 1)
            : nil
        return WatchVersionInformation(
            firmwareVersion: fixedString(frame.payload[5..<37]),
            serialNumber: fixedString(frame.payload[108..<120]),
            hardwarePlatform: frame.payload[46],
            isRunningRecoveryFirmware: FirmwareFlag.recovery.isSet(in: flags),
            runningFirmwareSlot: slot
        )
    }

    private static func fixedString(_ bytes: ArraySlice<UInt8>) -> String {
        let content = bytes.prefix { $0 != 0 }
        return String(decoding: content, as: UTF8.self)
    }
}

public enum WatchVersionCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case unexpectedMessage
    case truncatedResponse
}

public extension PebbleWatchModel {
    init?(hardwarePlatform: UInt8) {
        switch hardwarePlatform {
        case 15:
            self = .pebble2Duo
        case 13, 16, 17, 18, 243, 244, 247, 249:
            self = .pebbleTime2
        case 19, 20, 21:
            self = .pebbleRound2
        default:
            return nil
        }
    }
}
