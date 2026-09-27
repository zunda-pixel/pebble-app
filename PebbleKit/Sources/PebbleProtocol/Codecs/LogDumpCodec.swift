public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchLogLine: Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var date: Date
    /// Counted the way the firmware's own logging does: 1 is an error, 50 a
    /// warning, 100 informational, 200 debug.
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

    public var formatted: String {
        "\(levelName) \(date.formatted(.iso8601)) \(file):\(line)> \(message)"
    }
}

/// Generation zero is the run the watch is in now, one the run before it, and
/// so on back until it has no more.
public enum LogDumpCodec {
    public static var endpoint: UInt16 { 2_002 }

    static let requestCommand: UInt8 = 0x10
    static let lineCommand: UInt8 = 0x80
    static let doneCommand: UInt8 = 0x81
    static let noLogsCommand: UInt8 = 0x82

    // The watch copies these four bytes out of the request into every line of the
    // answer without reading them as a number, so a reply to an abandoned request
    // can be told apart from this one's.
    public static func requestFrame(generation: UInt8, cookie: UInt32) -> PebbleProtocolFrame {
        PebbleProtocolFrame(
            endpoint: endpoint,
            payload: [requestCommand, generation] + cookie.littleEndianBytes
        )
    }

    public enum Message: Equatable, Sendable {
        case line(WatchLogLine)
        case done
        /// The watch has been asked for further back than it goes.
        case noLogs
    }

    /// Not little-endian: the record is the firmware's own `LogBinaryMessage`,
    /// written to flash and dumped verbatim on an ARM watch, but
    /// `pbl_log_binary_format` puts the timestamp and line number through `htonl`
    /// and `htons` first.
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

/// What a generation held. A watch with nothing to send says so rather than
/// sending an empty dump, and the difference is worth keeping.
public enum LogDump: Equatable, Sendable {
    case lines([WatchLogLine])
    case noLogs
}

public struct LogDumpCollector: WatchPullCollector {
    private let cookie: UInt32
    private var lines: [WatchLogLine] = []

    public init(cookie: UInt32) {
        self.cookie = cookie
    }

    public mutating func accept(_ frame: PebbleProtocolFrame) throws -> LogDump? {
        switch try LogDumpCodec.decode(frame, cookie: cookie) {
        case .line(let line):
            lines.append(line)
            return nil
        case .done:
            return .lines(lines)
        case .noLogs:
            return .noLogs
        case nil:
            return nil
        }
    }
}

public enum WatchLogError: Error, Equatable, Sendable {
    case unexpectedEndpoint
    case invalidPayload
}
