import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Two built-in stores, each with its own feed, cache and index (#97).
@MainActor
@Suite
struct CatalogSourceTests {
    private static func feedAnswer(title: String) -> Data {
        Data("""
        {"applications": [{
            "id": "5f1e2d3c4b5a697887654321",
            "uuid": "A1A1A1A1-0000-0000-0000-000000000001",
            "title": "\(title)",
            "author": "tribute",
            "type": "watchface",
            "hardware_platforms": [{"name": "emery"}],
            "latest_release": {"pbw_file": "https://store.example/a.pbw", "version": "1.0"}
        }]}
        """.utf8)
    }

    /// The two home-feed addresses `update` asks, against a stubbed feed base.
    private static func answerHomeFeeds(base: URL, title: String) {
        for kind in ["apps", "faces"] {
            var components = URLComponents(
                url: base.appending(path: "v1/home").appending(path: kind),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "platform", value: "ios"),
                URLQueryItem(name: "filter_hardware", value: "true"),
            ]
            StoreStubURLProtocol.answer(components.url!, with: feedAnswer(title: title))
        }
    }

    /// One store's browsing must not answer another's: each source keeps a
    /// cache file of its own, and the Pebble store keeps the name from before
    /// sources existed so nobody's cache is thrown away.
    @Test func eachSourceKeepsItsOwnCache() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = URL(string: "https://stub.example/\(UUID().uuidString)/api")!
        let catalog = ApplicationCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session(),
            feedURL: feedURL
        )

        Self.answerHomeFeeds(base: feedURL, title: "Pebble Row")
        _ = try await catalog.update(platform: nil, source: .pebble)

        // The other store has not been fetched, so it has nothing — not the
        // Pebble store's rows.
        #expect(try await catalog.cachedSnapshot(source: .rebble) == nil)
        #expect(try await catalog.cachedSnapshot(source: .pebble)?.applications.count == 1)
        // And the Pebble cache landed in the pre-source file name.
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "catalog.json").path))

        Self.answerHomeFeeds(base: feedURL, title: "Rebble Row")
        _ = try await catalog.update(platform: nil, source: .rebble)

        #expect(try await catalog.cachedSnapshot(source: .pebble)?.applications.first?.name == "Pebble Row")
        #expect(try await catalog.cachedSnapshot(source: .rebble)?.applications.first?.name == "Rebble Row")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "catalog-rebble.json").path))
    }

    /// A row remembers which store listed it, and its store page follows: a
    /// Rebble identifier means nothing to the Pebble store's site.
    @Test func aRowsStorePageBelongsToTheStoreThatListedIt() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = URL(string: "https://stub.example/\(UUID().uuidString)/api")!
        let catalog = ApplicationCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session(),
            feedURL: feedURL
        )
        Self.answerHomeFeeds(base: feedURL, title: "Row")

        let rebble = try await catalog.update(platform: nil, source: .rebble).applications[0]
        #expect(rebble.source == .rebble)
        #expect(rebble.storePageURL?.absoluteString
            == "https://apps.rebble.io/application/5f1e2d3c4b5a697887654321")

        let pebble = try await catalog.update(platform: nil, source: .pebble).applications[0]
        #expect(pebble.storePageURL?.absoluteString
            == "https://apps.repebble.com/5f1e2d3c4b5a697887654321")
        #expect(pebble.source == .pebble)
    }

    /// A source is written down as its name and read back as this build's
    /// source of that name — never as the feed address it had when written.
    @Test func aSourceIsStoredByNameAndReadBackWhole() throws {
        let encoded = try JSONEncoder().encode(CatalogSource.rebble)

        #expect(String(decoding: encoded, as: UTF8.self) == "\"rebble\"")
        #expect(try JSONDecoder().decode(CatalogSource.self, from: encoded) == .rebble)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CatalogSource.self, from: Data("\"gone\"".utf8))
        }
    }

    /// The snapshot says which store it is, and a row whose store this build
    /// no longer knows keeps the row and falls back to the Pebble store.
    @Test func aSnapshotNamesItsSourceAndARowOfAnUnknownStoreIsKept() throws {
        let snapshot = CatalogSnapshot(source: .rebble, applications: [])
        let decoded = try JSONDecoder().decode(CatalogSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.source == .rebble)
        #expect(decoded.fetchedAt == nil)

        let row = try JSONDecoder().decode(CatalogApplication.self, from: Data("""
        {"id": "9AF9741D-28B9-4EC6-A978-F4265D988267", "name": "Zzz", "developer": "Z",
         "version": "1.0", "downloadURL": "https://example.com/a.pbw",
         "supportedPlatforms": ["emery"], "source": "gone"}
        """.utf8))
        #expect(row.source == .pebble)
    }

    /// A source that publishes no index cannot be searched past its shop
    /// window; the refusal reads as the failure banner, not as empty results.
    @Test func aSourceWithoutAnIndexRefusesToSearch() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = ApplicationCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session()
        )
        let indexless = CatalogSource(
            id: "custom",
            title: "Somebody's Store",
            feedURL: URL(string: "https://store.example/api")!,
            searchApplicationID: nil,
            searchAPIKey: nil,
            searchIndexName: nil,
            storePageBaseURL: URL(string: "https://store.example")!
        )

        await #expect(throws: ApplicationCatalogError.invalidResponse) {
            _ = try await catalog.search("mario", source: indexless)
        }
    }
}
