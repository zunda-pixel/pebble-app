public import Foundation
import CryptoKit
import MemberwiseInit

/// The remote catalog of installable applications.
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
            let actual = SHA256.hash(data: data).hexadecimalString
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
public enum AppCatalogError: Error, Equatable, Sendable {
    case invalidResponse
    case insecureURL
    case packageTooLarge
    case checksumMismatch
    case applicationIDMismatch
    case incompatibleHardware
}
