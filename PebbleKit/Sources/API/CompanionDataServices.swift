public import Foundation
import MemberwiseInit
import CryptoKit

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

    public func samples() throws -> [PebbleHealthSample] { try PersistentJSON.loadRecovering([PebbleHealthSample].self, from: fileURL) ?? [] }
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
    public var storeID: String = ""
    public var name: String
    public var developer: String
    public var version: String
    public var downloadURL: URL
    public var supportedPlatforms: [String]
    public var kind: PebbleApplicationKind = .watchapp
    public var category: String = "Other"
    public var summary: String = ""
    public var releaseNotes: String? = nil
    public var iconURL: URL? = nil
    public var screenshotURLs: [URL] = []
    public var sha256: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, storeID, name, developer, version, downloadURL, supportedPlatforms
        case kind, category, summary, releaseNotes, iconURL, screenshotURLs, sha256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        storeID = try container.decodeIfPresent(String.self, forKey: .storeID) ?? ""
        name = try container.decode(String.self, forKey: .name)
        developer = try container.decode(String.self, forKey: .developer)
        version = try container.decode(String.self, forKey: .version)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        supportedPlatforms = try container.decode([String].self, forKey: .supportedPlatforms)
        kind = try container.decodeIfPresent(PebbleApplicationKind.self, forKey: .kind) ?? .watchapp
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        screenshotURLs = try container.decodeIfPresent([URL].self, forKey: .screenshotURLs) ?? []
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
    }

    public func supports(_ model: PebbleWatchModel) -> Bool {
        !Set(supportedPlatforms).isDisjoint(with: model.compatibleApplicationVariants)
    }

    public func isNewer(than installedVersion: String?) -> Bool {
        guard let installedVersion else { return true }
        return version.compare(installedVersion, options: .numeric) == .orderedDescending
    }
}

@MemberwiseInit(.public)
public struct PebbleCatalogSnapshot: Codable, Equatable, Sendable {
    public var sourceURL: URL
    public var fetchedAt: Date = Date()
    public var applications: [PebbleCatalogApplication]
}

public actor PebbleAppCatalog {
    private var cacheURL: URL

    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? applicationSupportURL("catalog.json")
    }

    public func cachedSnapshot() throws -> PebbleCatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let data = try Data(contentsOf: cacheURL)
        if let snapshot = try? JSONDecoder().decode(PebbleCatalogSnapshot.self, from: data) { return snapshot }
        if let applications = try? JSONDecoder().decode([PebbleCatalogApplication].self, from: data) {
            return PebbleCatalogSnapshot(sourceURL: URL(string: "https://appstore-api.repebble.com/api")!, applications: applications)
        }
        try PersistentJSON.quarantine(cacheURL)
        return nil
    }

    public func cachedApplications() throws -> [PebbleCatalogApplication] { try cachedSnapshot()?.applications ?? [] }

    public func update(from sourceURL: URL, model: PebbleWatchModel?) async throws -> PebbleCatalogSnapshot {
        let applications: [PebbleCatalogApplication]
        if sourceURL.pathExtension.lowercased() == "json" {
            applications = try await fetchLegacyFeed(sourceURL)
        } else {
            async let watchapps = fetchOfficialHome(sourceURL, kind: .watchapp, model: model)
            async let watchfaces = fetchOfficialHome(sourceURL, kind: .watchface, model: model)
            applications = try await watchapps + watchfaces
        }
        let unique = Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
            .values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let snapshot = PebbleCatalogSnapshot(sourceURL: sourceURL, applications: unique)
        try PersistentJSON.save(snapshot, to: cacheURL)
        return snapshot
    }

    public func download(_ application: PebbleCatalogApplication) async throws -> URL {
        guard application.downloadURL.scheme?.lowercased() == "https" else { throw AppCatalogError.insecureURL }
        var request = URLRequest(url: application.downloadURL)
        request.timeoutInterval = 60
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppCatalogError.invalidResponse }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1_024 * 1_024 else {
            throw AppCatalogError.packageTooLarge
        }
        let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        if let expected = application.sha256?.lowercased() {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw AppCatalogError.checksumMismatch }
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "catalog-\(application.id.uuidString).pbw")
        try? FileManager.default.removeItem(at: output)
        try data.write(to: output, options: .atomic)
        return output
    }

    private func fetchLegacyFeed(_ url: URL) async throws -> [PebbleCatalogApplication] {
        let data = try await responseData(from: url)
        return try JSONDecoder().decode([PebbleCatalogApplication].self, from: data)
    }

    private func fetchOfficialHome(
        _ baseURL: URL,
        kind: PebbleApplicationKind,
        model: PebbleWatchModel?
    ) async throws -> [PebbleCatalogApplication] {
        var url = baseURL.appending(path: "v1/home").appending(path: kind == .watchapp ? "watchapps" : "watchfaces")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "filter_hardware", value: "true")]
        if let model { queryItems.append(URLQueryItem(name: "hardware", value: model.compatibleApplicationVariants.first)) }
        components?.queryItems = queryItems
        if let value = components?.url { url = value }
        let response = try JSONDecoder().decode(OfficialCatalogHome.self, from: await responseData(from: url))
        return response.applications.compactMap { $0.application(kind: kind) }
    }

    private func responseData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 20 * 1_024 * 1_024 else {
            throw AppCatalogError.invalidResponse
        }
        return data
    }
}

struct OfficialCatalogHome: Decodable {
    var applications: [OfficialCatalogApplication]
}

struct OfficialCatalogApplication: Decodable {
    var author: String
    var category: String
    var description: String
    var id: String
    var title: String
    var type: String
    var uuid: String?
    var hardwarePlatforms: [OfficialCatalogHardware]?
    var iconImage: [String: String]?
    var screenshotImages: [[String: String]]?
    var latestRelease: OfficialCatalogRelease?

    private enum CodingKeys: String, CodingKey {
        case author, category, description, id, title, type, uuid
        case hardwarePlatforms = "hardware_platforms"
        case iconImage = "icon_image"
        case screenshotImages = "screenshot_images"
        case latestRelease = "latest_release"
    }

    func application(kind: PebbleApplicationKind) -> PebbleCatalogApplication? {
        guard let uuid, let applicationID = UUID(uuidString: uuid),
              uuid.lowercased() != "00000000-0000-0000-0000-000000000000", let release = latestRelease,
              let downloadURL = URL(string: release.pbwFile),
              ["https", "http"].contains(downloadURL.scheme?.lowercased()) else { return nil }
        return PebbleCatalogApplication(
            id: applicationID,
            storeID: id,
            name: title,
            developer: author,
            version: release.version ?? "0",
            downloadURL: downloadURL,
            supportedPlatforms: hardwarePlatforms?.map(\.name) ?? ["aplite", "basalt", "chalk", "diorite", "emery", "flint", "gabbro"],
            kind: kind,
            category: category,
            summary: description,
            releaseNotes: release.releaseNotes,
            iconURL: iconImage?.values.compactMap(URL.init(string:)).first,
            screenshotURLs: screenshotImages?.flatMap { $0.values }.compactMap(URL.init(string:)) ?? []
        )
    }
}

struct OfficialCatalogHardware: Decodable { var name: String }
struct OfficialCatalogRelease: Decodable {
    var pbwFile: String
    var releaseNotes: String?
    var version: String?
    private enum CodingKeys: String, CodingKey {
        case pbwFile = "pbw_file"
        case releaseNotes = "release_notes"
        case version
    }
}

public actor PendingNotificationLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-notifications.json")
    }

    public func notifications() throws -> [PebbleTimelineNotification] {
        try PersistentJSON.loadRecovering([PebbleTimelineNotification].self, from: fileURL) ?? []
    }

    public func save(_ notifications: [PebbleTimelineNotification]) throws {
        try PersistentJSON.save(notifications, to: fileURL)
    }
}

@MemberwiseInit(.public)
public struct NotificationDeliveryPreferences: Codable, Equatable, Sendable {
    public var mutedApplicationIDs: Set<UUID> = []
    public var quietHoursEnabled: Bool = false
    public var quietHoursStart: Int = 22
    public var quietHoursEnd: Int = 7

    public func permits(applicationID: UUID, at date: Date, calendar: Calendar = .current) -> Bool {
        guard !mutedApplicationIDs.contains(applicationID) else { return false }
        guard quietHoursEnabled else { return true }
        let hour = calendar.component(.hour, from: date)
        if quietHoursStart == quietHoursEnd { return false }
        return quietHoursStart < quietHoursEnd
            ? !(quietHoursStart..<quietHoursEnd).contains(hour)
            : !(hour >= quietHoursStart || hour < quietHoursEnd)
    }
}

public actor NotificationPreferenceLibrary {
    private var fileURL: URL
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("notification-preferences.json")
    }
    public func preferences() throws -> NotificationDeliveryPreferences {
        try PersistentJSON.loadRecovering(NotificationDeliveryPreferences.self, from: fileURL) ?? NotificationDeliveryPreferences()
    }
    public func save(_ preferences: NotificationDeliveryPreferences) throws {
        try PersistentJSON.save(preferences, to: fileURL)
    }
}

public enum PendingTimelineOperation: Codable, Equatable, Sendable {
    case upsert(PebbleTimelinePin)
    case delete(UUID)
}

public actor PendingTimelineOperationLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-timeline.json")
    }

    public func operations() throws -> [PendingTimelineOperation] {
        try PersistentJSON.loadRecovering([PendingTimelineOperation].self, from: fileURL) ?? []
    }

    public func save(_ operations: [PendingTimelineOperation]) throws {
        try PersistentJSON.save(operations, to: fileURL)
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
    public func messages() throws -> [StoredAppMessage] { try PersistentJSON.loadRecovering([StoredAppMessage].self, from: fileURL) ?? [] }
    public func save(_ messages: [StoredAppMessage]) throws { try PersistentJSON.save(messages, to: fileURL) }
}

public actor PendingFirmwareUpdateLibrary {
    private var fileURL: URL
    private var journalURL: URL
    public func package() throws -> PBZFirmwarePackage? { try PersistentJSON.loadRecovering(PBZFirmwarePackage.self, from: fileURL) }
    public init(fileURL: URL? = nil, journalURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-firmware.json")
        self.journalURL = journalURL ?? applicationSupportURL("pending-firmware-journal.json")
    }
    public func journal() throws -> FirmwareUpdateJournal? {
        try PersistentJSON.loadRecovering(FirmwareUpdateJournal.self, from: journalURL)
    }
    public func save(_ package: PBZFirmwarePackage, journal: FirmwareUpdateJournal) throws {
        try PersistentJSON.save(package, to: fileURL)
        try PersistentJSON.save(journal, to: journalURL)
    }
    public func updatePhase(_ phase: FirmwareUpdatePhase) throws {
        guard var value = try journal() else { return }
        value.phase = phase
        try PersistentJSON.save(value, to: journalURL)
    }
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: journalURL)
    }
}

public enum FirmwareUpdatePhase: String, Codable, Equatable, Sendable {
    case validated, transferring, installing, awaitingRestart, cancelled
}

@MemberwiseInit(.public)
public struct FirmwareUpdateJournal: Codable, Equatable, Sendable {
    public var deviceID: String
    public var hardwareRevision: String
    public var previousVersion: String?
    public var targetVersion: String?
    public var packageSHA256: String
    public var phase: FirmwareUpdatePhase = .validated
    public var createdAt: Date = Date()
}

public enum HealthSyncCodec {
    public static var endpoint: UInt16 { 911 }

    public static func requestFrame(since date: Date?, now: Date = Date()) -> PebbleProtocolFrame {
        let interval = date.map { max(0, now.timeIntervalSince($0)) } ?? Double(UInt32.max)
        let seconds = UInt32(min(Double(UInt32.max), interval))
        return PebbleProtocolFrame(endpoint: endpoint, payload: [0x01] + seconds.littleEndianBytes)
    }
}

public enum AppCatalogError: Error, Equatable, Sendable {
    case invalidResponse
    case insecureURL
    case packageTooLarge
    case checksumMismatch
    case applicationIDMismatch
    case incompatibleHardware
}

enum PersistentJSON {
    static var maximumFileSize: Int { 64 * 1_024 * 1_024 }

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateFileSize(at: url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func loadRecovering<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try validateFileSize(at: url)
        } catch {
            try quarantine(url)
            return nil
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch is DecodingError {
            try quarantine(url)
            return nil
        }
    }

    static func quarantine(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backupURL = url
            .deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).corrupt-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: backupURL)
    }

    static func validateFileSize(at url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw CocoaError(.fileReadTooLarge) }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: littleEndian) { Array($0) } }
}

func applicationSupportURL(_ name: String) -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    return base.appending(path: "Pebble", directoryHint: .isDirectory).appending(path: name)
}
