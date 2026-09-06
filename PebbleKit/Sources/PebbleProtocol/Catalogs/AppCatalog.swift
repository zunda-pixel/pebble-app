public import Foundation
import Algorithms
import HTTPTypes
import HTTPTypesFoundation
import CryptoKit
import MemberwiseInit
import Retry

/// The remote catalog of installable applications.
@MemberwiseInit(.public)
public struct CatalogApplication: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var storeID: String = ""
    public var name: String
    public var developer: String
    public var version: String
    public var downloadURL: URL
    public var supportedPlatforms: [String]
    public var kind: WatchApplicationKind = .watchapp
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
        kind = try container.decodeIfPresent(WatchApplicationKind.self, forKey: .kind) ?? .watchapp
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Other"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        screenshotURLs = try container.decodeIfPresent([URL].self, forKey: .screenshotURLs) ?? []
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
    }

    /// The store's own page for this application, where there is one.
    ///
    /// Deliberately *not* the `links.share` the feed offers. That address is
    /// `apps.rebble.io/application/…`, the Rebble store, which does not know
    /// the applications published since — asked for one, it serves its own
    /// front page with nothing on it. Measured against three identifiers:
    /// `apps.rebble.io` names only the 2014-era one in its `og:title`, while
    /// `apps.repebble.com` names all three.
    ///
    /// Nil for an application the store does not know about: a hand-written
    /// feed carries no `storeID`, and neither does one side-loaded from a file.
    public var storePageURL: URL? {
        // Strict escaping because the legacy feed is whatever URL the reader
        // pointed at, so `storeID` is not the store's 24 hex digits by right.
        // Anything left unescaped would land the reader elsewhere on the site.
        guard !storeID.isEmpty,
              let id = storeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        // The bare identifier is where the store settles: its own
        // `/en_US/application/…` redirects here.
        return URL(string: "https://apps.repebble.com/\(id)")
    }

    public func supports(_ model: WatchModel) -> Bool {
        !Set(supportedPlatforms).isDisjoint(with: model.compatibleApplicationVariants)
    }

    public func isNewer(than installedVersion: String?) -> Bool {
        guard let installedVersion else { return true }
        return version.compare(installedVersion, options: .numeric) == .orderedDescending
    }
}

@MemberwiseInit(.public)
public struct CatalogSnapshot: Codable, Equatable, Sendable {
    public var sourceURL: URL
    public var fetchedAt: Date = Date()
    public var applications: [CatalogApplication]
}

public actor AppCatalog {
    /// Where applications are fetched from unless the user points elsewhere.
    public static var defaultSourceURL: URL {
        URL(string: "https://appstore-api.repebble.com/api")!
    }

    private var cacheURL: URL
    private let session: URLSession

    public init(directory: StorageDirectory = .applicationSupport, session: URLSession? = nil) {
        self.init(cacheURL: directory.file("catalog.json"), session: session)
    }

    public init(cacheURL: URL, session: URLSession? = nil) {
        self.cacheURL = cacheURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    public func cachedSnapshot() throws -> CatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let data = try Data(contentsOf: cacheURL)
        if let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) { return snapshot }
        if let applications = try? JSONDecoder().decode([CatalogApplication].self, from: data) {
            return CatalogSnapshot(sourceURL: Self.defaultSourceURL, applications: applications)
        }
        try PersistentJSON.quarantine(cacheURL)
        return nil
    }

    public func cachedApplications() throws -> [CatalogApplication] { try cachedSnapshot()?.applications ?? [] }

    public func update(from sourceURL: URL, model: WatchModel?) async throws -> CatalogSnapshot {
        let applications: [CatalogApplication]
        if sourceURL.pathExtension.lowercased() == "json" {
            applications = try await fetchLegacyFeed(sourceURL)
        } else {
            async let watchapps = fetchOfficialHome(sourceURL, kind: .watchapp, model: model)
            async let watchfaces = fetchOfficialHome(sourceURL, kind: .watchface, model: model)
            applications = try await watchapps + watchfaces
        }
        // Later entries win, so the newest description of an application is
        // the one kept.
        let unique = applications.reversed().uniqued(on: \.id)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let snapshot = CatalogSnapshot(sourceURL: sourceURL, applications: unique)
        try PersistentJSON.save(snapshot, to: cacheURL)
        return snapshot
    }

    public func download(_ application: CatalogApplication) async throws -> URL {
        let temporaryURL = try await retry(with: .networkFetch) {
            do {
                return try await downloadFile(from: application.downloadURL, using: session)
            } catch HTTPFileDownloadError.insecureURL {
                throw NotRetryable(AppCatalogError.insecureURL)
            } catch let error as HTTPFileDownloadError {
                throw error.isWorthAnotherAttempt
                    ? AppCatalogError.invalidResponse
                    : NotRetryable(AppCatalogError.invalidResponse)
            } catch {
                throw AppCatalogError.invalidResponse
            }
        }
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

    private func fetchLegacyFeed(_ url: URL) async throws -> [CatalogApplication] {
        let data = try await responseData(from: url)
        return try JSONDecoder().decode([CatalogApplication].self, from: data)
    }

    private func fetchOfficialHome(
        _ baseURL: URL,
        kind: WatchApplicationKind,
        model: WatchModel?
    ) async throws -> [CatalogApplication] {
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
        try await retry(with: .networkFetch) {
            let request = HTTPRequest(method: .get, url: url, headerFields: [.accept: "application/json"])
            let (data, response) = try await session.data(for: request)
            guard response.status == .ok else {
                let error = AppCatalogError.invalidResponse
                throw response.status.isWorthAnotherAttempt ? error : NotRetryable(error)
            }
            guard data.count <= 20 * 1_024 * 1_024 else {
                // The feed is this size on purpose; it will be next time too.
                throw NotRetryable(AppCatalogError.invalidResponse)
            }
            return data
        }
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

    func application(kind: WatchApplicationKind) -> CatalogApplication? {
        guard let uuid, let applicationID = UUID(uuidString: uuid),
              uuid.lowercased() != "00000000-0000-0000-0000-000000000000", let release = latestRelease,
              let downloadURL = URL(string: release.pbwFile),
              ["https", "http"].contains(downloadURL.scheme?.lowercased()) else { return nil }
        return CatalogApplication(
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
