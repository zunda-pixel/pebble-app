public import Foundation
import MemberwiseInit
import OSLog

public enum DiagnosticLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

@MemberwiseInit(.public)
public struct DiagnosticEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var timestamp: Date = Date()
    public var level: DiagnosticLevel
    public var category: String
    public var message: String
}

@MemberwiseInit(.public)
public struct DiagnosticReport: Encodable, Sendable {
    public var generatedAt: Date
    public var operatingSystem: String
    public var watchDescription: String?
    public var applications: [WatchApplication]
    public var entries: [DiagnosticEntry]
}

public actor DiagnosticLog {
    public static let shared = DiagnosticLog()

    private var entries: [DiagnosticEntry] = []
    private var maximumEntryCount: Int
    private var logger = Logger(subsystem: "dev.pebble.app", category: "diagnostics")
    /// Every frame that crosses the link, on its own channel.
    ///
    /// The endpoint, the direction and the size are enough to follow a whole
    /// conversation without decoding anything, which is what most of the
    /// diagnosing in this app has come down to — and they are of no use to
    /// anyone reading a report, which is the other thing this type is for.
    /// So they are logged where a person will not meet them by accident: their
    /// own category, at `debug`, and never in the report below.
    private let packetLogger = Logger(subsystem: "dev.pebble.app", category: "packet")

    public init(maximumEntryCount: Int = 500) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public func record(
        _ level: DiagnosticLevel = .info,
        category: String,
        message: String
    ) {
        let entry = DiagnosticEntry(level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        logger.log(level: logType(for: level), "[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    public func snapshot() -> [DiagnosticEntry] {
        entries
    }

    public func recordFrame(direction: String, frame: PebbleProtocolFrame) {
        let line = "\(direction) endpoint=\(frame.endpoint) bytes=\(frame.payload.count)"
        packetLogger.debug("\(line, privacy: .public)")
    }

    /// A frame the transport itself had no answer for, with its bytes.
    ///
    /// The app is handed every frame as well, so this is not "nobody wanted
    /// it" — and reading it that way sends the search for a missing feature to
    /// the wrong layer. It goes on the packet channel with the rest.
    public func recordUnansweredFrame(_ frame: PebbleProtocolFrame, tag: String) {
        let line = "[\(tag)] the transport has no answer for endpoint \(frame.endpoint): "
            + frame.payload.hexadecimalString
        packetLogger.debug("\(line, privacy: .public)")
    }

    public func exportReport(
        watch: ConnectedWatch?,
        applications: [WatchApplication],
        directory: URL = .temporaryDirectory
    ) throws -> URL {
        let report = DiagnosticReport(
            generatedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            // The board and the manufacturing revision are here because a
            // report about a watch that does not say which revision it is
            // cannot be matched against a hardware fault. Both read "unknown"
            // rather than being left out: their absence is itself worth
            // knowing, since an unrecognised board is why some watches have no
            // firmware screen.
            watchDescription: watch.map { watch in
                [
                    watch.name,
                    watch.model?.displayName ?? "unknown model",
                    watch.board?.rawValue ?? "unknown board",
                    watch.hardwareRevision ?? "unknown revision",
                    watch.firmwareVersion ?? "unknown",
                ].joined(separator: " / ")
            },
            applications: applications,
            entries: entries
        )
        // A colon is a path separator to some of the places a report is sent on
        // to, so the time is written without one rather than repaired after.
        let when = report.generatedAt.formatted(.iso8601.timeSeparator(.omitted))
        let filename = "pebble-diagnostics-\(when).json"
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    private func logType(for level: DiagnosticLevel) -> OSLogType {
        switch level {
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}
