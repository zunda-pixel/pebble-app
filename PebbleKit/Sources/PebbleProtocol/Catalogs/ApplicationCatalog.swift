public import Foundation
import Algorithms
import HTTPTypes
import HTTPTypesFoundation
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
    /// What the store's row says the application uses, in the store's own
    /// codes. Empty for a row that predates this field, and for one the store
    /// gave nothing for.
    public var capabilities: [String] = []
    /// Which store listed it — `CatalogSource.id`. Nil for a row cached before
    /// sources existed, which can only have come from the Pebble store.
    public var sourceID: String? = nil
    /// Every published version the store told of, newest first. Empty for a
    /// row cached before this was kept, and for a store that says nothing —
    /// which is also what hides the version-history entrance.
    public var changelog: [CatalogChangelogEntry] = []

    public var declaredCapabilities: [WatchApplicationCapability] {
        WatchApplicationCapability.declared(in: capabilities)
    }

    private enum CodingKeys: String, CodingKey {
        case id, storeID, name, developer, version, downloadURL, supportedPlatforms
        case kind, category, summary, releaseNotes, iconURL, screenshotURLs
        case capabilities, sourceID, changelog
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
        // Absent from every cache written before this field existed, which is
        // why it decodes to empty rather than refusing the whole row.
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
        changelog = try container.decodeIfPresent([CatalogChangelogEntry].self, forKey: .changelog) ?? []
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
        // The page belongs to the store that listed the row: a Rebble row's
        // identifier means nothing to the Pebble store's site. Joined as a
        // string because `id` is already percent-encoded — `appending(path:)`
        // would encode the escapes themselves.
        return URL(string: CatalogSource.named(sourceID).storePageBaseURL.absoluteString + "/" + id)
    }

    public func supports(_ model: WatchModel) -> Bool {
        !Set(supportedPlatforms).isDisjoint(with: model.compatibleApplicationVariants)
    }

    public func isNewer(than installedVersion: String?) -> Bool {
        guard let installedVersion else { return true }
        return version.compare(installedVersion, options: .numeric) == .orderedDescending
    }
}

/// One of the store's shelves: Top Picks, Most Loved, and whatever else the
/// feed curates. Login-free by nature — the Heart-backed one is account
/// territory and deliberately absent (#107).
@MemberwiseInit(.public)
public struct CatalogCollection: Codable, Equatable, Identifiable, Sendable {
    /// The store's own slug, unique within one kind of one feed.
    public var slug: String
    /// The store's title, shown verbatim: the shelf is the store's to name.
    public var name: String
    /// Which home it came off — the store keeps one for apps and one for faces,
    /// and `top-picks` exists on both as two different shelves.
    public var kind: WatchApplicationKind
    /// The store's own path for the full listing, server-relative
    /// (`/api/v1/apps/collection/top-picks/faces`).
    public var appsPath: String? = nil

    public var id: String { "\(kind.rawValue)/\(slug)" }
}

@MemberwiseInit(.public)
public struct CatalogSnapshot: Codable, Equatable, Sendable {
    public var sourceURL: URL
    public var fetchedAt: Date = Date()
    public var applications: [CatalogApplication]
    /// The feed's shelves, faces first to match the applications' own mixing.
    /// Empty for a cache written before these were kept.
    public var collections: [CatalogCollection] = []

    private enum CodingKeys: String, CodingKey {
        case sourceURL, fetchedAt, applications, collections
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? Date()
        applications = try container.decode([CatalogApplication].self, forKey: .applications)
        collections = try container.decodeIfPresent([CatalogCollection].self, forKey: .collections) ?? []
    }
}

/// One page of a collection's full listing, and whether the store has more.
@MemberwiseInit(.public)
public struct CatalogCollectionPage: Equatable, Sendable {
    public var applications: [CatalogApplication]
    public var hasMore: Bool
}

public actor ApplicationCatalog {
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
    /// Internal for the search extension beside this file, which posts to the
    /// store's index with the same session the feed is fetched with.
    let session: URLSession
    /// Overrides so a test can stand a stub at addresses of its own; nil
    /// everywhere real, where the source names both.
    let searchURLOverride: URL?
    let feedURLOverride: URL?

    public init(directory: StorageDirectory = .applicationSupport, session: URLSession? = nil) {
        self.init(cacheURL: directory.file("catalog.json"), session: session)
    }

    public init(cacheURL: URL, session: URLSession? = nil, searchURL: URL? = nil, feedURL: URL? = nil) {
        self.searchURLOverride = searchURL
        self.feedURLOverride = feedURL
        self.cacheURL = cacheURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The cache file for one source. The Pebble store keeps the name from
    /// before sources existed, so nobody's cache is thrown away by the rename
    /// that never happened; every other source gets a sibling of its own —
    /// two stores sharing a file would answer each other's browsing.
    private func cacheURL(for source: CatalogSource) -> URL {
        guard source.id != CatalogSource.pebble.id else { return cacheURL }
        let stem = cacheURL.deletingPathExtension().lastPathComponent
        return cacheURL
            .deletingLastPathComponent()
            .appending(path: "\(stem)-\(source.id).json")
    }

    public func cachedSnapshot(source: CatalogSource = .pebble) throws -> CatalogSnapshot? {
        let cacheURL = cacheURL(for: source)
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let data = try Data(contentsOf: cacheURL)
        if let snapshot = try? JSONDecoder().decode(CatalogSnapshot.self, from: data) { return snapshot }
        if let applications = try? JSONDecoder().decode([CatalogApplication].self, from: data) {
            // The array predates snapshots, and only the Pebble store ever
            // wrote one — but the provenance is the asked-for source's, not
            // hardcoded, or a misnamed legacy file would claim the wrong feed.
            return CatalogSnapshot(sourceURL: source.feedURL, applications: applications)
        }
        try PersistentJSON.quarantine(cacheURL)
        return nil
    }

    public func update(model: WatchModel?, source: CatalogSource = .pebble) async throws -> CatalogSnapshot {
        // The test override wins where one was injected; the source names the
        // feed everywhere real.
        let sourceURL = feedURLOverride ?? source.feedURL
        async let watchapps = fetchOfficialHome(sourceURL, kind: .watchapp, model: model, source: source)
        async let watchfaces = fetchOfficialHome(sourceURL, kind: .watchface, model: model, source: source)
        let (apps, faces) = try await (watchapps, watchfaces)
        let applications = apps.applications + faces.applications
        // Later entries win, so the newest description of an application is
        // the one kept.
        let unique = applications.reversed().uniqued(on: \.id)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let snapshot = CatalogSnapshot(
            sourceURL: sourceURL,
            applications: unique,
            collections: faces.collections + apps.collections
        )
        try PersistentJSON.save(snapshot, to: cacheURL(for: source))
        return snapshot
    }

    /// One page of a collection's full listing, from the path the feed gave.
    /// - Parameter hardware: The connected watch's board, which decides the
    ///   screenshots and the compatibility filter, as everywhere else.
    public func collectionPage(
        _ collection: CatalogCollection,
        offset: Int,
        limit: Int = 20,
        hardware: String? = nil,
        source: CatalogSource = .pebble
    ) async throws -> CatalogCollectionPage {
        guard let url = collectionPageURL(
            for: collection,
            offset: offset,
            limit: limit,
            hardware: hardware,
            baseURL: feedURLOverride ?? source.feedURL
        ) else { throw ApplicationCatalogError.invalidResponse }
        let response = try JSONDecoder().decode(OfficialCatalogPage.self, from: await responseData(from: url))
        return CatalogCollectionPage(
            applications: response.data.compactMap {
                // The entry's own word first: an apps shelf can hold faces and
                // the other way round is not this app's to rule out.
                $0.application(kind: $0.declaredKind ?? collection.kind, sourceID: source.id)
            },
            hasMore: response.links?.nextPage != nil
        )
    }

    /// The path is the store's own, server-relative, so it resolves against
    /// the feed's host rather than being appended to the feed's `/api` base —
    /// the path already carries it.
    func collectionPageURL(
        for collection: CatalogCollection,
        offset: Int,
        limit: Int,
        hardware: String?,
        baseURL: URL
    ) -> URL? {
        guard let appsPath = collection.appsPath,
              let resolved = URL(string: appsPath, relativeTo: baseURL) else { return nil }
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true)
        var queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "filter_hardware", value: "true"),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let hardware { queryItems.append(URLQueryItem(name: "hardware", value: hardware)) }
        components?.queryItems = queryItems
        return components?.url
    }

    public func download(_ application: CatalogApplication) async throws -> URL {
        let temporaryURL = try await retry(with: .networkFetch) {
            do {
                return try await downloadFile(from: application.downloadURL, using: session)
            } catch HTTPFileDownloadError.insecureURL {
                throw NotRetryable(ApplicationCatalogError.insecureURL)
            } catch let error as HTTPFileDownloadError {
                throw error.isWorthAnotherAttempt
                    ? ApplicationCatalogError.invalidResponse
                    : NotRetryable(ApplicationCatalogError.invalidResponse)
            } catch {
                throw ApplicationCatalogError.invalidResponse
            }
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard try downloadedFileSize(at: temporaryURL) <= 64 * 1_024 * 1_024 else {
            throw ApplicationCatalogError.packageTooLarge
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "catalog-\(application.id.uuidString).pbw")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporaryURL, to: output)
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
    /// - Parameter hardware: The connected watch's board, which the endpoint
    ///   honours (measured 2026-09-12: `?hardware=aplite` answers aplite
    ///   screenshots where the default was basalt). Nil asks for the store's
    ///   default, which is right when no watch is connected.
    public func application(
        uuid: UUID,
        from baseURL: URL,
        hardware: String? = nil,
        sourceID: String? = nil
    ) async throws -> CatalogApplication? {
        var url = baseURL.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased())
        if let hardware {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "hardware", value: hardware)]
            if let value = components?.url { url = value }
        }
        guard let data = try await responseDataAllowingNotFound(from: url) else { return nil }
        let response = try JSONDecoder().decode(OfficialCatalogLookup.self, from: data)
        // The kind comes off the entry rather than the endpoint here: this one
        // is asked by identifier, so it answers with whatever that is.
        return response.data.lazy.compactMap { $0.application(kind: nil, sourceID: sourceID) }.first
    }

    private func fetchOfficialHome(
        _ baseURL: URL,
        kind: WatchApplicationKind,
        model: WatchModel?,
        source: CatalogSource
    ) async throws -> (applications: [CatalogApplication], collections: [CatalogCollection]) {
        // `apps` and `faces`, the official application's own spelling
        // (`AppType.storeString()`): the Pebble store answers the longer
        // `watchapps`/`watchfaces` as well, but the Rebble store answers only
        // these — the other spelling is a 404 that cost the whole catalogue
        // (measured 2026-09-12).
        var url = baseURL.appending(path: "v1/home").appending(path: kind == .watchapp ? "apps" : "faces")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "filter_hardware", value: "true")]
        if let model { queryItems.append(URLQueryItem(name: "hardware", value: model.compatibleApplicationVariants.first)) }
        components?.queryItems = queryItems
        if let value = components?.url { url = value }
        let response = try JSONDecoder().decode(OfficialCatalogHome.self, from: await responseData(from: url))
        return (
            applications: response.applications.compactMap { $0.application(kind: kind, sourceID: source.id) },
            collections: response.catalogCollections(kind: kind)
        )
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
                let error = ApplicationCatalogError.invalidResponse
                throw response.status.isWorthAnotherAttempt ? error : NotRetryable(error)
            }
            guard data.count <= 20 * 1_024 * 1_024 else {
                throw NotRetryable(ApplicationCatalogError.invalidResponse)
            }
            return data
        }
    }

    private func responseData(from url: URL) async throws -> Data {
        try await retry(with: .networkFetch) {
            let request = HTTPRequest(method: .get, url: url, headerFields: [.accept: "application/json"])
            let (data, response) = try await session.data(for: request)
            guard response.status == .ok else {
                let error = ApplicationCatalogError.invalidResponse
                throw response.status.isWorthAnotherAttempt ? error : NotRetryable(error)
            }
            guard data.count <= 20 * 1_024 * 1_024 else {
                // The feed is this size on purpose; it will be next time too.
                throw NotRetryable(ApplicationCatalogError.invalidResponse)
            }
            return data
        }
    }
}

struct OfficialCatalogHome: Decodable {
    var applications: [OfficialCatalogApplication]
    /// The feed's shelves. Optional like everything off this wire.
    var collections: [OfficialCatalogCollection]?

    /// The shelves worth showing: one with neither a listing path nor a name
    /// is nothing a screen can open or label, and costs itself alone.
    func catalogCollections(kind: WatchApplicationKind) -> [CatalogCollection] {
        (collections ?? []).compactMap { shelf in
            guard let slug = shelf.slug?.nilWhenEmpty,
                  let name = shelf.name?.nilWhenEmpty,
                  let appsPath = shelf.links?["apps"]?.nilWhenEmpty else { return nil }
            return CatalogCollection(slug: slug, name: name, kind: kind, appsPath: appsPath)
        }
    }
}

/// Optional fields for the reason every `OfficialCatalog…` field is.
struct OfficialCatalogCollection: Decodable {
    var name: String?
    var slug: String?
    var links: [String: String]?
}

/// One page of a paged listing: the rows, and the store's own word on whether
/// there are more.
struct OfficialCatalogPage: Decodable {
    var data: [OfficialCatalogApplication]
    var links: OfficialCatalogPageLinks?
}

struct OfficialCatalogPageLinks: Decodable {
    var nextPage: String?
}

/// One application asked for by identifier. Answered as a list of one, which
/// is the shape the store uses for everything it pages.
struct OfficialCatalogLookup: Decodable {
    var data: [OfficialCatalogApplication]
}

/// One entry as the store sends it.
///
/// Every field is optional but the ones an entry cannot be shown without, and
/// those are checked in `application(kind:)` so that an entry this app cannot
/// use costs that entry and not the response it arrived in. A plain `String`
/// here throws `keyNotFound`, and these decode inside an array — so one bad
/// entry in `v1/home/watchapps` lost all 73 of the day's featured applications,
/// while the guard written to skip exactly such an entry never ran.
struct OfficialCatalogApplication: Decodable {
    var author: String?
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
    var id: String?
    var title: String?
    var type: String?
    var uuid: String?
    /// What the store says the application uses: `health`, `location`,
    /// `timeline`, `configurable`. Optional for the reason every field here is.
    var capabilities: [String]?
    var hardwarePlatforms: [OfficialCatalogHardware]?
    var iconImage: [String: String]?
    var screenshotImages: [[String: String]]?
    var latestRelease: OfficialCatalogRelease?

    /// Every published version, as the store lists them.
    var changelog: [OfficialCatalogChangelogEntry]?

    private enum CodingKeys: String, CodingKey {
        case author, capabilities, category, description, id, title, type, uuid, changelog
        case hardwarePlatforms = "hardware_platforms"
        case iconImage = "icon_image"
        case screenshotImages = "screenshot_images"
        case latestRelease = "latest_release"
    }

    /// The kind the entry says it is, for a lookup that was not made against a
    /// watchapps or watchfaces endpoint and so has nothing else to go on.
    var declaredKind: WatchApplicationKind? {
        type.flatMap(WatchApplicationKind.init(rawValue:))
    }

    /// - Parameter kind: What the endpoint this came from was asked for, or nil
    ///   to take the entry's own word for it.
    func application(kind: WatchApplicationKind?, sourceID: String? = nil) -> CatalogApplication? {
        guard let kind = kind ?? declaredKind else { return nil }
        guard let uuid, let applicationID = UUID(uuidString: uuid),
              uuid.lowercased() != "00000000-0000-0000-0000-000000000000", let release = latestRelease,
              let pbwFile = release.pbwFile,
              let downloadURL = URL(string: pbwFile),
              // Only https is ever downloaded (`downloadFile`), so a plain
              // http package would be a row that cannot be installed.
              downloadURL.scheme?.lowercased() == "https",
              // A row needs both of these, so an entry the store will not name
              // or attribute is one to skip — the same answer this already
              // gives an entry with no UUID.
              let title, let author else { return nil }
        return CatalogApplication(
            id: applicationID,
            storeID: id?.nilWhenEmpty,
            name: title,
            developer: author,
            version: release.version ?? "0",
            downloadURL: downloadURL,
            supportedPlatforms: hardwarePlatforms?.compactMap(\.name) ?? ["aplite", "basalt", "chalk", "diorite", "emery", "flint", "gabbro"],
            kind: kind,
            // The store sends `"category": ""` as readily as it omits the key,
            // and both mean the same thing to a reader.
            category: category?.nilWhenEmpty,
            summary: description?.nilWhenEmpty,
            releaseNotes: release.releaseNotes,
            iconURL: iconImage?.values.compactMap(URL.init(string:)).first,
            screenshotURLs: screenshotImages?.flatMap { $0.values }.compactMap(URL.init(string:)) ?? [],
            capabilities: capabilities ?? [],
            sourceID: sourceID,
            // Newest first however the store ordered them; an entry that names
            // no version has nothing to head its row and costs itself alone.
            changelog: (changelog ?? [])
                .compactMap { entry -> CatalogChangelogEntry? in
                    guard let version = entry.version?.nilWhenEmpty else { return nil }
                    return CatalogChangelogEntry(
                        version: version,
                        publishedAt: OfficialCatalogChangelogEntry.date(entry.publishedDate),
                        notes: entry.releaseNotes?.nilWhenEmpty
                    )
                }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        )
    }
}

/// One row of an application's published history, as this app keeps it.
@MemberwiseInit(.public)
public struct CatalogChangelogEntry: Codable, Equatable, Sendable {
    public var version: String
    /// Nil where the store gave no date, or one this app could not read.
    public var publishedAt: Date? = nil
    public var notes: String? = nil
}

/// Optional fields for the reason every `OfficialCatalog…` field is: one
/// half-written entry must cost itself, not the response it arrived in.
struct OfficialCatalogChangelogEntry: Decodable {
    var version: String?
    var publishedDate: String?
    var releaseNotes: String?
    private enum CodingKeys: String, CodingKey {
        case version
        case publishedDate = "published_date"
        case releaseNotes = "release_notes"
    }

    /// The store writes `2026-09-21T01:49:41.888` — fractional seconds, no
    /// zone. The times are the store's own clock, which serves UTC, so a
    /// zoneless one is read as UTC rather than dropped.
    static func date(_ string: String?) -> Date? {
        guard let string = string?.nilWhenEmpty else { return nil }
        let zoned = string.contains("Z") || string.contains("+") ? string : string + "Z"
        return (try? Date(zoned, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(zoned, strategy: .iso8601))
    }
}

/// Optional for the reason above: one platform in `hardware_platforms`
/// without a name would otherwise have cost the whole response.
struct OfficialCatalogHardware: Decodable { var name: String? }
struct OfficialCatalogRelease: Decodable {
    /// Optional, and the clearest case of the fault above: `application(kind:)`
    /// below already drops an entry whose `pbw_file` will not parse as an
    /// `https` URL, so a release with no usable download was meant to cost one
    /// entry. A *missing* key threw before that guard could run and cost the
    /// response instead — a pulled release taking the catalogue with it.
    var pbwFile: String?
    var releaseNotes: String?
    var version: String?
    private enum CodingKeys: String, CodingKey {
        case pbwFile = "pbw_file"
        case releaseNotes = "release_notes"
        case version
    }
}
public enum ApplicationCatalogError: Error, Equatable, Sendable {
    case invalidResponse
    case insecureURL
    case packageTooLarge
    case applicationIDMismatch
}

extension String {
    /// Nothing, where an empty string means the same as no string.
    ///
    /// Used at the two decoding boundaries above and nowhere else, on purpose:
    /// the store can say either, and it is the boundary's job to settle that so
    /// no reader downstream has to ask twice.
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}
