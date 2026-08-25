public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleHealthSample: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date
    public var steps: Int
    public var sleepMinutes: Int
}

public actor PebbleHealthLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("health.json")
    }

    public func samples() throws -> [PebbleHealthSample] { try PersistentJSON.load([PebbleHealthSample].self, from: fileURL) ?? [] }
    public func save(_ samples: [PebbleHealthSample]) throws { try PersistentJSON.save(samples, to: fileURL) }
    public func merge(_ incoming: [PebbleHealthSample]) throws -> [PebbleHealthSample] {
        var values = try samples()
        for sample in incoming {
            values.removeAll { Calendar.current.isDate($0.date, inSameDayAs: sample.date) }
            values.append(sample)
        }
        values.sort { $0.date < $1.date }
        try save(values)
        return values
    }
    public func deleteAll() throws { try? FileManager.default.removeItem(at: fileURL) }
    public func export() throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "pebble-health.json")
        try JSONEncoder().encode(try samples()).write(to: output, options: .atomic)
        return output
    }
}

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

    public static func requestFrame(since date: Date?) -> PebbleProtocolFrame {
        let seconds = UInt32(max(0, min(Double(UInt32.max), date?.timeIntervalSince1970 ?? 0)))
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
