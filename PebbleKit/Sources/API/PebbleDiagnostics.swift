public import Foundation
import MemberwiseInit
import OSLog

public enum PebbleDiagnosticLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

@MemberwiseInit(.public)
public struct PebbleDiagnosticEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var timestamp: Date = Date()
    public var level: PebbleDiagnosticLevel
    public var category: String
    public var message: String
}

@MemberwiseInit(.public)
public struct PebbleDiagnosticReport: Encodable, Sendable {
    public var generatedAt: Date
    public var operatingSystem: String
    public var deviceDescription: String?
    public var applications: [PebbleApplication]
    public var entries: [PebbleDiagnosticEntry]
}

public actor PebbleDiagnostics {
    public static let shared = PebbleDiagnostics()

    private var entries: [PebbleDiagnosticEntry] = []
    private var maximumEntryCount: Int
    private var logger = Logger(subsystem: "dev.pebble.app", category: "diagnostics")

    public init(maximumEntryCount: Int = 500) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    public func record(
        _ level: PebbleDiagnosticLevel = .info,
        category: String,
        message: String
    ) {
        let entry = PebbleDiagnosticEntry(level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        logger.log(level: logType(for: level), "[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    public func snapshot() -> [PebbleDiagnosticEntry] {
        entries
    }

    public func recordFrame(direction: String, frame: PebbleProtocolFrame) {
        record(
            category: "packet",
            message: "\(direction) endpoint=\(frame.endpoint) bytes=\(frame.payload.count)"
        )
    }

    public func exportReport(
        device: PebbleDevice?,
        applications: [PebbleApplication],
        directory: URL = .temporaryDirectory
    ) throws -> URL {
        let report = PebbleDiagnosticReport(
            generatedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceDescription: device.map {
                "\($0.name) / \($0.model.displayName) / \($0.firmwareVersion)"
            },
            applications: applications,
            entries: entries
        )
        let formatter = ISO8601DateFormatter()
        let filename = "pebble-diagnostics-\(formatter.string(from: report.generatedAt)).json"
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    private func logType(for level: PebbleDiagnosticLevel) -> OSLogType {
        switch level {
        case .info: .info
        case .warning: .default
        case .error: .error
        }
    }
}
