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
    /// Two round trips by design: the index answers with rankings but without
    /// a hit's release — no `latest_release`, measured against the live index
    /// (2026-09-11) — so a hit alone cannot become a row the install path can
    /// use. The identifiers go back to the feed's own bulk endpoint, the way
    /// the official application resolves hits (`fetchAppMetadataByIds`), and
    /// come back as the same full entries the home feed is made of.
    ///
    /// `kind` narrows by the index's own tags. The phone-platform tag `ios` is
    /// always sent, the way the official application sends it; the hardware
    /// platform deliberately is not — the index does not tag every compatible
    /// application with every board, so filtering there loses real results.
    /// Compatibility is judged per row instead, by `supportedPlatforms`.
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
            applications: try await applications(ids: answer.hits.compactMap(\.id)),
            page: answer.page,
            pageCount: answer.nbPages,
            totalCount: answer.nbHits
        )
    }

    /// The full store entries for these identifiers, in the order they were
    /// asked for — which is the index's ranking. An identifier the feed does
    /// not answer for costs that row alone.
    func applications(ids: [String]) async throws -> [CatalogApplication] {
        guard !ids.isEmpty else { return [] }
        let request = HTTPRequest(
            method: .post,
            url: feedURL.appending(path: "v1/apps/bulk"),
            headerFields: [.contentType: "application/json", .accept: "application/json"]
        )
        let (data, response) = try await session.upload(
            for: request,
            from: try JSONEncoder().encode(BulkLookup(ids: ids))
        )
        guard response.status == .ok, data.count <= 20 * 1_024 * 1_024 else {
            throw AppCatalogError.invalidResponse
        }
        // The same rows the feed itself is made of, so the same decoding. The
        // answer's order is the server's own and is put back into the asked
        // one, keyed by the store identifier both sides carry.
        let entries = try JSONDecoder().decode(OfficialCatalogLookup.self, from: data)
        let byID = Dictionary(
            entries.data.compactMap { entry -> (String, CatalogApplication)? in
                guard let application = entry.application(kind: nil), let id = application.storeID
                else { return nil }
                return (id, application)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.compactMap { byID[$0] }
    }
}

private struct AlgoliaQuery: Encodable {
    var query: String
    var page: Int
    var hitsPerPage: Int
    var tagFilters: [String]
}

private struct BulkLookup: Encodable {
    var ids: [String]
}

struct AlgoliaSearchResponse: Decodable {
    var hits: [CatalogSearchHit]
    var page: Int
    var nbPages: Int
    var nbHits: Int
}

/// One hit as the index sends it. Only the store identifier is kept: the hit
/// has no release to install from, so everything shown comes from the feed's
/// own entry, fetched by this identifier.
struct CatalogSearchHit: Decodable {
    var id: String?
}
