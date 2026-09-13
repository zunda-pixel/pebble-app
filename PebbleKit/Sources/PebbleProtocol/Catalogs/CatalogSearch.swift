import Foundation
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

extension ApplicationCatalog {
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
    /// - Parameter preferredHardware: The connected watch's boards, most
    ///   compatible first. The bulk endpoint ignores its hardware parameter
    ///   (measured 2026-09-12) and answers each application's default board,
    ///   so the screenshots come from the hit's own per-board collections
    ///   instead, which the index does carry.
    public func search(
        _ query: String,
        kind: WatchApplicationKind? = nil,
        page: Int = 0,
        preferredHardware: [String] = [],
        source: CatalogSource = .pebble
    ) async throws -> CatalogSearchPage {
        // A source without an index cannot be searched past its shop window;
        // refusing reads as the failure banner rather than as empty results.
        guard let searchQueryURL = source.searchQueryURL,
              let applicationID = source.searchApplicationID,
              let apiKey = source.searchAPIKey
        else { throw ApplicationCatalogError.invalidResponse }
        var tags = ["ios"]
        if let kind { tags.append(kind == .watchface ? "watchface" : "watchapp") }
        let body = AlgoliaQuery(query: query, page: page, hitsPerPage: 20, tagFilters: tags)
        let request = HTTPRequest(
            method: .post,
            url: searchURLOverride ?? searchQueryURL,
            headerFields: [
                .init("X-Algolia-Application-Id")!: applicationID,
                .init("X-Algolia-API-Key")!: apiKey,
                .contentType: "application/json",
                .accept: "application/json",
            ]
        )
        let (data, response) = try await session.upload(
            for: request,
            from: try JSONEncoder().encode(body)
        )
        guard response.status == .ok, data.count <= 20 * 1_024 * 1_024 else {
            throw ApplicationCatalogError.invalidResponse
        }
        let answer = try JSONDecoder().decode(AlgoliaSearchResponse.self, from: data)
        let collections = Dictionary(
            answer.hits.compactMap { hit -> (String, [CatalogSearchAssetCollection])? in
                guard let id = hit.id, let assetCollections = hit.assetCollections else { return nil }
                return (id, assetCollections)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let resolved = try await applications(ids: answer.hits.compactMap(\.id), source: source)
            .map { application -> CatalogApplication in
                guard let id = application.storeID,
                      let urls = Self.screenshotURLs(
                          from: collections[id] ?? [],
                          preferred: preferredHardware
                      )
                else { return application }
                var chosen = application
                chosen.screenshotURLs = urls
                return chosen
            }
        return CatalogSearchPage(
            applications: resolved,
            page: answer.page,
            pageCount: answer.nbPages,
            totalCount: answer.nbHits
        )
    }

    /// The screenshots for the most preferred board that has any, or nil to
    /// keep the entry's own — the bulk answer's default board, better than
    /// nothing where the collections do not cover this watch.
    static func screenshotURLs(
        from collections: [CatalogSearchAssetCollection],
        preferred: [String]
    ) -> [URL]? {
        for board in preferred {
            guard let collection = collections.first(where: { $0.hardwarePlatform == board })
            else { continue }
            let urls = (collection.screenshots ?? []).compactMap(URL.init(string:))
            if !urls.isEmpty { return urls }
        }
        return nil
    }

    /// The full store entries for these identifiers, in the order they were
    /// asked for — which is the index's ranking. An identifier the feed does
    /// not answer for costs that row alone.
    func applications(ids: [String], source: CatalogSource = .pebble) async throws -> [CatalogApplication] {
        guard !ids.isEmpty else { return [] }
        let request = HTTPRequest(
            method: .post,
            url: (feedURLOverride ?? source.feedURL).appending(path: "v1/apps/bulk"),
            headerFields: [.contentType: "application/json", .accept: "application/json"]
        )
        let (data, response) = try await session.upload(
            for: request,
            from: try JSONEncoder().encode(BulkLookup(ids: ids))
        )
        guard response.status == .ok, data.count <= 20 * 1_024 * 1_024 else {
            throw ApplicationCatalogError.invalidResponse
        }
        // The same rows the feed itself is made of, so the same decoding. The
        // answer's order is the server's own and is put back into the asked
        // one, keyed by the store identifier both sides carry.
        let entries = try JSONDecoder().decode(OfficialCatalogLookup.self, from: data)
        let byID = Dictionary(
            entries.data.compactMap { entry -> (String, CatalogApplication)? in
                guard let application = entry.application(kind: nil, sourceID: source.id),
                      let id = application.storeID
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

/// One hit as the index sends it. The store identifier names the feed entry
/// everything else comes from — the hit has no release to install from — and
/// the per-board screenshot collections are kept because they are the one
/// thing the feed's bulk answer cannot say for this watch.
struct CatalogSearchHit: Decodable {
    var id: String?
    var assetCollections: [CatalogSearchAssetCollection]?

    private enum CodingKeys: String, CodingKey {
        case id
        case assetCollections = "asset_collections"
    }
}

struct CatalogSearchAssetCollection: Decodable {
    var hardwarePlatform: String?
    var screenshots: [String]?

    private enum CodingKeys: String, CodingKey {
        case hardwarePlatform = "hardware_platform"
        case screenshots
    }
}
