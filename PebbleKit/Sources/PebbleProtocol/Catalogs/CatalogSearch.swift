public import Foundation
import HTTPTypes
import HTTPTypesFoundation

/// One page of what the store's search index answered.
///
/// Pages are the index's own — Algolia counts from zero and says how many
/// there are — so "is there more" is arithmetic here rather than a guess.
public struct CatalogSearchPage: Equatable, Sendable {
    public var applications: [CatalogApplication]
    public var page: Int
    public var pageCount: Int
    public var totalCount: Int

    public var hasMore: Bool { page + 1 < pageCount }
}

extension AppCatalog {
    /// The store's search index.
    ///
    /// The home feed is a shop window: fetching it shows the featured lists,
    /// and this app's search box used to only sift those. The store's whole
    /// inventory is reachable only through its Algolia index, which is what
    /// the official application searches (`AppstoreService.search`). The
    /// credentials are the search-only public pair shipped in the official
    /// application's own binary (`AppstoreSources.kt`), tied to the same feed
    /// `defaultSourceURL` names.
    static var searchApplicationID: String { "GM3S9TRYO4" }
    static var searchAPIKey: String { "0b83b4f8e4e8e9793d2f1f93c21894aa" }
    static var searchIndexName: String { "apps" }

    public static var searchQueryURL: URL {
        URL(string: "https://\(searchApplicationID)-dsn.algolia.net/1/indexes/\(searchIndexName)/query")!
    }

    /// Asks the store's index, one page at a time.
    ///
    /// `kind` narrows by the index's own tags. The phone-platform tag `ios` is
    /// always sent, the way the official application sends it; the hardware
    /// platform deliberately is not — the index does not tag every compatible
    /// application with every board, so filtering there loses real results.
    /// Compatibility is answered per row instead, by `supportedPlatforms`.
    public func search(
        _ query: String,
        kind: WatchApplicationKind? = nil,
        page: Int = 0
    ) async throws -> CatalogSearchPage {
        var tags = ["ios"]
        if let kind { tags.append(kind == .watchface ? "watchface" : "watchapp") }
        let body = AlgoliaQuery(query: query, page: page, hitsPerPage: 20, tagFilters: tags)
        let request = HTTPRequest(
            method: .post,
            url: searchURL,
            headerFields: [
                .init("X-Algolia-Application-Id")!: Self.searchApplicationID,
                .init("X-Algolia-API-Key")!: Self.searchAPIKey,
                .contentType: "application/json",
                .accept: "application/json",
            ]
        )
        let (data, response) = try await session.upload(
            for: request,
            from: try JSONEncoder().encode(body)
        )
        guard response.status == .ok, data.count <= 20 * 1_024 * 1_024 else {
            throw AppCatalogError.invalidResponse
        }
        let answer = try JSONDecoder().decode(AlgoliaSearchResponse.self, from: data)
        return CatalogSearchPage(
            applications: answer.hits.compactMap { $0.application() },
            page: answer.page,
            pageCount: answer.nbPages,
            totalCount: answer.nbHits
        )
    }
}

private struct AlgoliaQuery: Encodable {
    var query: String
    var page: Int
    var hitsPerPage: Int
    var tagFilters: [String]
}

struct AlgoliaSearchResponse: Decodable {
    var hits: [CatalogSearchHit]
    var page: Int
    var nbPages: Int
    var nbHits: Int
}

/// One hit as the index sends it (`StoreSearchResult` in the official
/// application). Every field is optional but the ones a row cannot be shown or
/// installed without, and those are checked in `application()` — so a hit this
/// app cannot use costs that hit and not the page it arrived in, the same
/// bargain `OfficialCatalogApplication` strikes.
struct CatalogSearchHit: Decodable {
    var author: String?
    var category: String?
    var description: String?
    var title: String?
    var type: String?
    var uuid: String?
    var id: String?
    var version: String?
    var iconImage: String?
    var screenshotImages: [String]?
    var latestRelease: CatalogSearchRelease?
    var compatibility: [String: CatalogSearchCompatibility]?

    private enum CodingKeys: String, CodingKey {
        case author, category, description, title, type, uuid, id, version, compatibility
        case iconImage = "icon_image"
        case screenshotImages = "screenshot_images"
        case latestRelease = "latest_release"
    }

    /// The boards the store's own compatibility table names, which every entry
    /// in the index carries. The watch platforms are the keys that are not
    /// phone platforms.
    private var supportedPlatforms: [String] {
        let phones: Set<String> = ["ios", "android"]
        let supported = (compatibility ?? [:])
            .filter { !phones.contains($0.key) && $0.value.supported == true }
            .keys
        return supported.isEmpty
            ? ["aplite", "basalt", "chalk", "diorite", "emery", "flint", "gabbro"]
            : supported.sorted()
    }

    func application() -> CatalogApplication? {
        guard let uuid, let applicationID = UUID(uuidString: uuid),
              uuid.lowercased() != "00000000-0000-0000-0000-000000000000",
              let pbwFile = latestRelease?.pbwFile,
              let downloadURL = URL(string: pbwFile),
              ["https", "http"].contains(downloadURL.scheme?.lowercased()),
              let title, let author,
              let kind = type.flatMap(WatchApplicationKind.init(rawValue:))
        else { return nil }
        return CatalogApplication(
            id: applicationID,
            storeID: id?.nilWhenEmpty,
            name: title,
            developer: author,
            version: version?.nilWhenEmpty ?? "0",
            downloadURL: downloadURL,
            supportedPlatforms: supportedPlatforms,
            kind: kind,
            category: category?.nilWhenEmpty,
            summary: description?.nilWhenEmpty,
            iconURL: iconImage.flatMap(URL.init(string:)),
            screenshotURLs: screenshotImages?.compactMap(URL.init(string:)) ?? []
        )
    }
}

struct CatalogSearchRelease: Decodable {
    var pbwFile: String?
    private enum CodingKeys: String, CodingKey { case pbwFile = "pbw_file" }
}

struct CatalogSearchCompatibility: Decodable {
    var supported: Bool?
}
