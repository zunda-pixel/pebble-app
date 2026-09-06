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
    /// The store's own identifier, nil for an application it does not know —
    /// one installed from a file, or a catalogue cached before this was kept.
    public var storeID: String? = nil
    public var name: String
    public var developer: String
    public var version: String
    public var downloadURL: URL
    public var supportedPlatforms: [String]
    public var kind: WatchApplicationKind = .watchapp
    /// What the store called it — `Games`, `Tools & Utilities`. Nil when the
    /// store did not say.
    ///
    /// This was `"Other"`, which put an English word this app had made up into
    /// a model that otherwise only carries the store's own. It reached the
    /// screen through `Text(_:)` given a `String`, the overload that does not
    /// localize, so it showed in English however the phone was set — and the
    /// localization test could not see it, because a plain `String` is never
    /// extracted into the catalogue.
    ///
    /// Then it was `""`, which is no better a way to say "absent": every
    /// reader had to know that the empty string was not a category, and two of
    /// them wrote `if let x, !x.isEmpty` — an optional and a sentinel checked
    /// one after the other for one question. Absence has a spelling in this
    /// language and `releaseNotes` beside it already used it.
    ///
    /// An empty string off the wire is normalised away in `init(from:)` and in
    /// `OfficialCatalogApplication`, so the boundary is the only place that has
    /// to know the store can say either.
    public var category: String? = nil
    public var summary: String? = nil
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
        storeID = try container.decodeIfPresent(String.self, forKey: .storeID)?.nilWhenEmpty
        name = try container.decode(String.self, forKey: .name)
        developer = try container.decode(String.self, forKey: .developer)
        version = try container.decode(String.self, forKey: .version)
        downloadURL = try container.decode(URL.self, forKey: .downloadURL)
        supportedPlatforms = try container.decode([String].self, forKey: .supportedPlatforms)
        kind = try container.decodeIfPresent(WatchApplicationKind.self, forKey: .kind) ?? .watchapp
        // Normalised here, so no reader downstream has to treat "" as absence.
        // The cache these come out of was written by earlier versions of this
        // app, which wrote "" for a category the store had not given. The
        // version before that wrote `"Other"`, which is left alone: the store
        // is entitled to a category of that name, and a cache holding the old
        // one is replaced by the next fetch anyway.
        category = try container.decodeIfPresent(String.self, forKey: .category)?.nilWhenEmpty
        summary = try container.decodeIfPresent(String.self, forKey: .summary)?.nilWhenEmpty
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)?.nilWhenEmpty
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
    /// Nil for an application the store does not know about — one installed
    /// from a file, or a catalogue cached before `storeID` was recorded.
    public var storePageURL: URL? {
        // Escaped strictly all the same. `storeID` comes off a cache that a
        // previous version of this app wrote, so it is not the store's 24 hex
        // digits by right, and anything left unescaped would land the reader
        // elsewhere on the site.
        // Empty is refused as well as nil. The two decoding boundaries never
        // produce one, but the memberwise initializer will take it from code,
        // and an empty identifier percent-encodes to an empty string — so
        // without this the link becomes the store's front page dressed up as
        // one application's. This is the type's own invariant, checked once
        // here rather than by every screen that reads the field.
        guard let storeID, !storeID.isEmpty,
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
    /// The store. The only one there is.
    ///
    /// This used to be a default the reader could replace in Settings, which
    /// bought one thing — a hand-written feed of `[CatalogApplication]` under
    /// a `.json` address — and cost every feature built on the store's own
    /// API, each of which had to do nothing for such a feed. Installing a
    /// package of one's own is what the file importer is for.
    ///
    /// If the store moves again, as it did once already, this is the line to
    /// change.
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

    public func update(model: WatchModel?) async throws -> CatalogSnapshot {
        let sourceURL = Self.defaultSourceURL
        async let watchapps = fetchOfficialHome(sourceURL, kind: .watchapp, model: model)
        async let watchfaces = fetchOfficialHome(sourceURL, kind: .watchface, model: model)
        let applications = try await watchapps + watchfaces
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

    /// What the store says about an application, asked for by the identifier
    /// the package carries.
    ///
    /// The way to reach the store for something already installed. A package
    /// says nothing about which store entry it came from — `appinfo.json` is
    /// the developer's, written before there was a listing — but the store
    /// will answer to the UUID inside it, so nothing has to be remembered at
    /// install time and a side-loaded package is looked up just the same.
    ///
    /// Nil where the store does not have it, which is an answer worth keeping:
    /// plenty of packages were never listed.
    public func application(uuid: UUID, from baseURL: URL) async throws -> CatalogApplication? {
        let url = baseURL.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased())
        guard let data = try await responseDataAllowingNotFound(from: url) else { return nil }
        let response = try JSONDecoder().decode(OfficialCatalogLookup.self, from: data)
        // The kind comes off the entry rather than the endpoint here: this one
        // is asked by identifier, so it answers with whatever that is.
        return response.data.lazy.compactMap { $0.application(kind: nil) }.first
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

    /// Nil where the store said it has no such application.
    ///
    /// Separate from `responseData(from:)` because there a 404 is a broken
    /// feed, while here it is the answer to the question asked.
    private func responseDataAllowingNotFound(from url: URL) async throws -> Data? {
        try await retry(with: .networkFetch) {
            let request = HTTPRequest(method: .get, url: url, headerFields: [.accept: "application/json"])
            let (data, response) = try await session.data(for: request)
            if response.status == .notFound { return nil }
            guard response.status == .ok else {
                let error = AppCatalogError.invalidResponse
                throw response.status.isWorthAnotherAttempt ? error : NotRetryable(error)
            }
            guard data.count <= 20 * 1_024 * 1_024 else {
                throw NotRetryable(AppCatalogError.invalidResponse)
            }
            return data
        }
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

/// One application asked for by identifier. Answered as a list of one, which
/// is the shape the store uses for everything it pages.
struct OfficialCatalogLookup: Decodable {
    var data: [OfficialCatalogApplication]
}

struct OfficialCatalogApplication: Decodable {
    var author: String
    /// Optional because the store need not send it, and one entry without it
    /// was enough to lose the response it arrived in.
    ///
    /// This was a plain `String`. A missing key throws `keyNotFound`, and this
    /// is decoded inside an array inside `OfficialCatalogLookup`, so a single
    /// uncategorised application in `v1/home/watchapps` — 73 of them the day
    /// this was measured — would have failed the whole catalogue fetch, and a
    /// by-UUID lookup would have looked like an application the store does not
    /// have. The `"Other"` that `CatalogApplication.category` used to default
    /// to could never be reached through this path at all.
    var category: String?
    /// Optional for the same reason as `category` above: a plain `String` here
    /// throws `keyNotFound` on an entry that omits it, and one such entry in an
    /// array loses the whole response it arrived in.
    var description: String?
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

    /// The kind the entry says it is, for a lookup that was not made against a
    /// watchapps or watchfaces endpoint and so has nothing else to go on.
    var declaredKind: WatchApplicationKind? {
        WatchApplicationKind(rawValue: type)
    }

    /// - Parameter kind: What the endpoint this came from was asked for, or nil
    ///   to take the entry's own word for it.
    func application(kind: WatchApplicationKind?) -> CatalogApplication? {
        guard let kind = kind ?? declaredKind else { return nil }
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
            // The store sends `"category": ""` as readily as it omits the key,
            // and both mean the same thing to a reader.
            category: category?.nilWhenEmpty,
            summary: description?.nilWhenEmpty,
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

extension String {
    /// Nothing, where an empty string means the same as no string.
    ///
    /// Used at the two decoding boundaries above and nowhere else, on purpose:
    /// the store can say either, and it is the boundary's job to settle that so
    /// no reader downstream has to ask twice.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
