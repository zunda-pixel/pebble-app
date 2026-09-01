public import Foundation
import MemberwiseInit

/// A line the watch wrote to its own log.
@MemberwiseInit(.public)
public struct WatchLogLine: Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    /// The firmware's level, counted the way its own logging does: 1 is an
    /// error, 50 a warning, 100 informational, 200 debug.
    public var level: UInt8
    public var file: String
    public var line: UInt16
    public var message: String

    public var levelName: String {
        switch level {
        case 0...1: "E"
        case 2...50: "W"
        case 51...100: "I"
        case 101...200: "D"
        default: "V"
        }
    }

    /// The line as it would look in a log file.
    public var formatted: String {
        "\(levelName) \(date.formatted(.iso8601)) \(file):\(line)> \(message)"
    }
}

/// The watch's log, which it keeps in flash and hands over a generation at a
/// time — generation zero being the run it is in now, one the run before it,
/// and so on back until it has no more.
public enum LogDumpCodec {
    public static var endpoint: UInt16 { 2_002 }

    static let requestCommand: UInt8 = 0x10
    static let lineCommand: UInt8 = 0x80
    static let doneCommand: UInt8 = 0x81
    static let noLogsCommand: UInt8 = 0x82

    /// The cookie comes back on every line of the answer, which is how a reply
    /// to an abandoned request is told apart from this one's.
    ///
    /// The watch copies the four bytes out of the request and back into every
    /// reply without ever reading them as a number, so the order they go out in
    /// only has to be the order they are read back in.
    public static func requestFrame(generation: UInt8, cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [requestCommand, generation] + cookie.littleEndianBytes
        )
    }

    public enum Message: Equatable, Sendable {
        case line(WatchLogLine)
        case done
        /// There is no such generation: the watch has been asked for further
        /// back than it goes.
        case noLogs
    }

    /// The record is the firmware's own `LogBinaryMessage`, whose two numbers
    /// `pbl_log_binary_format` puts through `htonl` and `htons` before it hands
    /// the buffer over, so they arrive most significant byte first.
    public static func decode(_ frame: PebbleProtocolFrame, cookie: UInt32) throws -> Message? {
        guard frame.endpoint == endpoint else { throw WatchLogError.unexpectedEndpoint }
        guard frame.payload.count >= 5 else { throw WatchLogError.invalidPayload }
        guard UInt32(littleEndianBytes: frame.payload[1..<5]) == cookie else { return nil }

        switch frame.payload[0] {
        case doneCommand:
            return .done
        case noLogsCommand:
            return .noLogs
        case lineCommand:
            return .line(try decodeLine(Array(frame.payload.dropFirst(5))))
        default:
            return nil
        }
    }

    static func decodeLine(_ bytes: [UInt8]) throws -> WatchLogLine {
        guard bytes.count >= 24 else { throw WatchLogError.invalidPayload }
        let timestamp = UInt32(bigEndianBytes: bytes[0..<4])
        let level = bytes[4]
        let length = Int(bytes[5])
        let line = UInt16(bigEndianBytes: bytes[6..<8])
        let file = String(decoding: bytes[8..<24].prefix { $0 != 0 }, as: UTF8.self)
        let message = String(decoding: bytes.dropFirst(24).prefix(length), as: UTF8.self)
        return WatchLogLine(
            date: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            level: level,
            file: file,
            line: line,
            message: message
        )
    }
}

/// The log of the apps running on the watch, which the watch only sends while
/// it has been asked to.
public enum AppLogCodec {
    public static var endpoint: UInt16 { 2_006 }

    public static func enableFrame(_ isEnabled: Bool) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [isEnabled ? 1 : 0])
    }

    /// The same record as a firmware log line, behind the identifier of the app
    /// that wrote it.
    public static func decode(_ frame: PebbleProtocolFrame) throws -> (applicationID: UUID, line: WatchLogLine) {
        guard frame.endpoint == endpoint else { throw WatchLogError.unexpectedEndpoint }
        guard frame.payload.count >= 16 else { throw WatchLogError.invalidPayload }
        let hex = frame.payload[0..<16].hexadecimalString
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let id = UUID(uuidString: formatted) else { throw WatchLogError.invalidPayload }
        return (id, try LogDumpCodec.decodeLine(Array(frame.payload.dropFirst(16))))
    }
}

public enum WatchLogError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
}
