public import Foundation

/// One log line and the watch app that wrote it — the pair the endpoint
/// carries, named once here for both the codec and the client event.
public struct ApplicationLogLine: Sendable, Equatable {
    public var applicationID: UUID
    public var line: WatchLogLine

    public init(applicationID: UUID, line: WatchLogLine) {
        self.applicationID = applicationID
        self.line = line
    }
}

public enum AppLogCodec {
    public static var endpoint: UInt16 { 2_006 }

    public static func enableFrame(_ isEnabled: Bool) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [isEnabled ? 1 : 0])
    }

    public static func decode(_ frame: PebbleProtocolFrame) throws -> ApplicationLogLine {
        guard frame.endpoint == endpoint else { throw WatchLogError.unexpectedEndpoint }
        guard frame.payload.count >= 16 else { throw WatchLogError.invalidPayload }
        let hex = frame.payload[0..<16].hexadecimalString
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: formatted) else { throw WatchLogError.invalidPayload }
        return ApplicationLogLine(
            applicationID: id,
            line: try LogDumpCodec.decodeLine(Array(frame.payload.dropFirst(16)))
        )
    }
}
