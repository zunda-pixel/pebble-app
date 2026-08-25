public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleHealthSample: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date
    public var steps: Int
    public var sleepMinutes: Int
    public var timeZoneIdentifier: String = TimeZone.current.identifier
    public var source: PebbleHealthDataSource = .watch
    public var updatedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, date, steps, sleepMinutes, timeZoneIdentifier, source, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        steps = try container.decode(Int.self, forKey: .steps)
        sleepMinutes = try container.decode(Int.self, forKey: .sleepMinutes)
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
        source = try container.decodeIfPresent(PebbleHealthDataSource.self, forKey: .source) ?? .watch
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
    }
}

public enum PebbleHealthDataSource: String, Codable, Equatable, Sendable {
    case watch
    case healthKit
    case imported
}

@MemberwiseInit(.public)
public struct PebbleHealthArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var exportedAt: Date = Date()
    public var samples: [PebbleHealthSample]
}

public actor PebbleHealthLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("health.json")
    }

    public func samples() throws -> [PebbleHealthSample] { try PersistentJSON.load([PebbleHealthSample].self, from: fileURL) ?? [] }
    public func save(_ samples: [PebbleHealthSample]) throws { try PersistentJSON.save(samples, to: fileURL) }
    public func merge(_ incoming: [PebbleHealthSample]) throws -> [PebbleHealthSample] {
        var merged: [String: PebbleHealthSample] = [:]
        for sample in try samples() + incoming {
            let normalized = normalized(sample)
            let key = dayKey(for: normalized)
            guard let existing = merged[key] else {
                merged[key] = normalized
                continue
            }
            var resolved = normalized.updatedAt >= existing.updatedAt ? normalized : existing
            resolved.steps = max(existing.steps, normalized.steps)
            if normalized.sleepMinutes > 0 && normalized.updatedAt >= existing.updatedAt {
                resolved.sleepMinutes = normalized.sleepMinutes
            } else {
                resolved.sleepMinutes = existing.sleepMinutes
            }
            merged[key] = resolved
        }
        var values = Array(merged.values)
        values.sort { $0.date < $1.date }
        try save(values)
        return values
    }
    public func deleteAll() throws { try? FileManager.default.removeItem(at: fileURL) }
    public func export() throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "pebble-health.json")
        let archive = PebbleHealthArchive(samples: try samples())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: output, options: .atomic)
        return output
    }

    public func importArchive(from url: URL) throws -> [PebbleHealthSample] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(PebbleHealthArchive.self, from: data) {
            guard archive.schemaVersion == 1 else { throw PebbleHealthArchiveError.unsupportedVersion }
            return try merge(archive.samples.map { sample in
                var value = sample
                value.source = .imported
                return value
            })
        }
        let legacyDecoder = JSONDecoder()
        let legacy = try legacyDecoder.decode([PebbleHealthSample].self, from: data)
        return try merge(legacy.map { sample in
            var value = sample
            value.source = .imported
            return value
        })
    }

    private func normalized(_ sample: PebbleHealthSample) -> PebbleHealthSample {
        var value = sample
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: sample.timeZoneIdentifier) ?? .current
        value.date = calendar.startOfDay(for: sample.date)
        value.steps = max(0, sample.steps)
        value.sleepMinutes = min(24 * 60, max(0, sample.sleepMinutes))
        return value
    }

    private func dayKey(for sample: PebbleHealthSample) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: sample.timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: sample.date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

public enum PebbleHealthArchiveError: Error, Equatable, Sendable { case unsupportedVersion }

public enum HealthAnalysisPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, quarter
    public var id: Self { self }
    public var days: Int { self == .week ? 7 : self == .month ? 30 : 90 }
}

@MemberwiseInit(.public)
public struct PebbleCatalogApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var developer: String
    public var version: String
    public var downloadURL: URL
    public var supportedPlatforms: [String]
}

public actor PebbleAppCatalog {
    private var cacheURL: URL

    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? applicationSupportURL("catalog.json")
    }

    public func cachedApplications() throws -> [PebbleCatalogApplication] {
        try PersistentJSON.load([PebbleCatalogApplication].self, from: cacheURL) ?? []
    }

    public func update(from sourceURL: URL) async throws -> [PebbleCatalogApplication] {
        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppCatalogError.invalidResponse }
        let applications = try JSONDecoder().decode([PebbleCatalogApplication].self, from: data)
        try PersistentJSON.save(applications, to: cacheURL)
        return applications
    }
}

public actor PendingNotificationLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-notifications.json")
    }

    public func notifications() throws -> [PebbleTimelineNotification] {
        try PersistentJSON.load([PebbleTimelineNotification].self, from: fileURL) ?? []
    }

    public func save(_ notifications: [PebbleTimelineNotification]) throws {
        try PersistentJSON.save(notifications, to: fileURL)
    }
}

@MemberwiseInit(.public)
public struct StoredAppMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var applicationID: UUID
    public var tuples: [AppMessageTuple]
    public var createdAt: Date = Date()
}

public actor PendingAppMessageLibrary {
    private var fileURL: URL
    public init(fileURL: URL? = nil) { self.fileURL = fileURL ?? applicationSupportURL("pending-appmessages.json") }
    public func messages() throws -> [StoredAppMessage] { try PersistentJSON.load([StoredAppMessage].self, from: fileURL) ?? [] }
    public func save(_ messages: [StoredAppMessage]) throws { try PersistentJSON.save(messages, to: fileURL) }
}

public actor PendingFirmwareUpdateLibrary {
    private var fileURL: URL
    public init(fileURL: URL? = nil) { self.fileURL = fileURL ?? applicationSupportURL("pending-firmware.json") }
    public func package() throws -> PBZFirmwarePackage? { try PersistentJSON.load(PBZFirmwarePackage.self, from: fileURL) }
    public func save(_ package: PBZFirmwarePackage) throws { try PersistentJSON.save(package, to: fileURL) }
    public func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

public enum HealthSyncCodec {
    public static var endpoint: UInt16 { 911 }

    public static func requestFrame(since date: Date?, now: Date = Date()) -> PebbleProtocolFrame {
        let interval = date.map { max(0, now.timeIntervalSince($0)) } ?? Double(UInt32.max)
        let seconds = UInt32(min(Double(UInt32.max), interval))
        return PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + seconds.littleEndianBytes)
    }
}

public enum AppCatalogError: Error, Equatable, Sendable { case invalidResponse }

private enum PersistentJSON {
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}

private func applicationSupportURL(_ name: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return base.appending(path: "Pebble", directoryHint: .isDirectory).appending(path: name)
}
