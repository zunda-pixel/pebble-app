public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct AppFetchRequest: Equatable, Sendable {
    public var applicationID: UUID
    public var appBankID: UInt32
}

public enum AppFetchResponseStatus: Equatable, Sendable {
    case start
    case busy
    case invalidApplicationID
    case noData

    /// `AppFetchInstallResult` in the firmware's own order. Saying "no data"
    /// with the starting value leaves the watch waiting for a transfer that
    /// will never come, until it gives up fifteen seconds later.
    var wireValue: UInt8 {
        switch self {
        case .start:
            0x01
        case .busy:
            0x02
        case .invalidApplicationID:
            0x03
        case .noData:
            0x04
        }
    }
}

public enum AppFetchCodec {
    public static var endpoint: UInt16 { 6_001 }

    public static func decodeRequest(_ frame: PebbleProtocolFrame) throws -> AppFetchRequest {
        guard frame.endpoint == endpoint else {
            throw AppFetchCodecError.unexpectedEndpoint
        }
        guard frame.payload.count == 21, frame.payload[0] == 0x01 else {
            throw AppFetchCodecError.invalidPayload
        }

        let uuidBytes = frame.payload[1..<17]
        let hexadecimalDigits = Array("0123456789ABCDEF")
        let hex = uuidBytes.flatMap { byte in
            [hexadecimalDigits[Int(byte >> 4)], hexadecimalDigits[Int(byte & 0x0F)]]
        }
        let hexString = String(hex)
        let uuidString = "\(hexString.prefix(8))-\(hexString.dropFirst(8).prefix(4))-\(hexString.dropFirst(12).prefix(4))-\(hexString.dropFirst(16).prefix(4))-\(hexString.dropFirst(20))"
        guard let applicationID = UUID(uuidString: uuidString) else {
            throw AppFetchCodecError.invalidApplicationID
        }
        let appBankID = UInt32(frame.payload[17])
            | UInt32(frame.payload[18]) << 8
            | UInt32(frame.payload[19]) << 16
            | UInt32(frame.payload[20]) << 24
        return AppFetchRequest(applicationID: applicationID, appBankID: appBankID)
    }

    public static func responseFrame(status: AppFetchResponseStatus) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x01, status.wireValue])
    }
}

public enum AppFetchCodecError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
    case invalidApplicationID
}
