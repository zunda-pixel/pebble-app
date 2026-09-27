public import Foundation

/// One store the catalog can browse: a feed, and where that store publishes
/// one, the search index that covers its whole inventory.
///
/// Both built-ins are the official application's own (`AppstoreSources.kt`),
/// credentials included — the Algolia pairs are search-only public keys
/// shipped in its binary. A source with no index browses and installs but
/// cannot be searched past its shop window.
public struct CatalogSource: Identifiable, Equatable, Sendable, Codable {
    /// Stable across launches — the stored selection and the per-source cache
    /// file are both named by it.
    public var id: String
    /// The store's own name, shown verbatim: a proper noun, not this app's
    /// word to translate.
    public var title: String
    public var feedURL: URL
    public var searchApplicationID: String?
    public var searchAPIKey: String?
    public var searchIndexName: String?
    /// Where the store's own web page for an application lives, by its store
    /// identifier.
    public var storePageBaseURL: URL

    public var searchQueryURL: URL? {
        guard let searchApplicationID, let searchIndexName else { return nil }
        return URL(string: "https://\(searchApplicationID)-dsn.algolia.net/1/indexes/\(searchIndexName)/query")
    }

    public static let pebble = CatalogSource(
        id: "pebble",
        title: "Pebble App Store",
        feedURL: URL(string: "https://appstore-api.repebble.com/api")!,
        searchApplicationID: "GM3S9TRYO4",
        searchAPIKey: "0b83b4f8e4e8e9793d2f1f93c21894aa",
        searchIndexName: "apps",
        // The bare identifier is where the store settles: its own
        // `/en_US/application/…` redirects here.
        storePageBaseURL: URL(string: "https://apps.repebble.com")!
    )

    public static let rebble = CatalogSource(
        id: "rebble",
        title: "Rebble App Store",
        feedURL: URL(string: "https://appstore-api.rebble.io/api")!,
        searchApplicationID: "7683OW76EQ",
        searchAPIKey: "252f4938082b8693a8a9fc0157d1d24f",
        searchIndexName: "rebble-appstore-production",
        storePageBaseURL: URL(string: "https://apps.rebble.io/application")!
    )

    public static let builtIn: [CatalogSource] = [.pebble, .rebble]
}

/// Written as its identifier and read back as today's built-in of that name.
///
/// Not the whole value: the feed address, the index and its key are this
/// build's to know, and a copy written by an earlier one would keep asking a
/// store that has since moved — which is what storing the feed's address and
/// looking the source up by it came to.
extension CatalogSource {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let id = try container.decode(String.self)
        guard let source = Self.builtIn.first(where: { $0.id == id }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "No built-in catalog source is named \(id)."
            )
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}
