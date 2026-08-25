public import Foundation
import MemberwiseInit

public enum AppRunStateEvent: Equatable, Sendable {
    case started(UUID)
    case stopped(UUID)
}

public enum AppRunStateCodec {
    public static var endpoint: UInt16 { 52 }

    public static func startFrame(applicationID: UUID) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + BlobDBCodec.uuidBytes(applicationID))
    }

    public static func stopFrame(applicationID: UUID) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x02] + BlobDBCodec.uuidBytes(applicationID))
    }

    public static func requestFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x03])
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> AppRunStateEvent {
        guard frame.endpoint == endpoint, frame.payload.count >= 17 else {
            throw AppRunStateCodecError.invalidPayload
        }
        let id = try uuid(Array(frame.payload[1..<17]))
        switch frame.payload[0] {
        case 0x01: return .started(id)
        case 0x02: return .stopped(id)
        default: throw AppRunStateCodecError.invalidPayload
        }
    }

    private static func uuid(_ bytes: [UInt8]) throws -> UUID {
        guard bytes.count == 16 else { throw AppRunStateCodecError.invalidPayload }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: value) else { throw AppRunStateCodecError.invalidPayload }
        return id
    }
}

public enum AppRunStateCodecError: Error, Equatable, Sendable { case invalidPayload }

@MemberwiseInit(.public)
public struct PebbleRetryPolicy: Equatable, Sendable {
    public var maximumAttempts: Int = 3
    public var initialDelay: Duration = .milliseconds(250)
    public var maximumDelay: Duration = .seconds(2)

    public func execute<Value: Sendable>(
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 0
        var delay = initialDelay
        while true {
            do { return try await operation() }
            catch {
                attempt += 1
                guard attempt < maximumAttempts, !Task.isCancelled else { throw error }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, maximumDelay)
            }
        }
    }
}
