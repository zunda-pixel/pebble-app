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
        let catalog = AppCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session(),
            feedURL: feedURL
        )

        Self.answerHomeFeeds(base: feedURL, title: "Pebble Row")
        _ = try await catalog.update(model: nil, source: .pebble)

        // The other store has not been fetched, so it has nothing — not the
        // Pebble store's rows.
        #expect(try await catalog.cachedSnapshot(source: .rebble) == nil)
        #expect(try await catalog.cachedSnapshot(source: .pebble)?.applications.count == 1)
        // And the Pebble cache landed in the pre-source file name.
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "catalog.json").path))

        Self.answerHomeFeeds(base: feedURL, title: "Rebble Row")
        _ = try await catalog.update(model: nil, source: .rebble)

        #expect(try await catalog.cachedSnapshot(source: .pebble)?.applications.first?.name == "Pebble Row")
        #expect(try await catalog.cachedSnapshot(source: .rebble)?.applications.first?.name == "Rebble Row")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "catalog-rebble.json").path))
    }

    /// A row remembers which store listed it, and its store page follows: a
    /// Rebble identifier means nothing to the Pebble store's site. A row cached
    /// before sources existed can only have come from the Pebble store.
    @Test func aRowsStorePageBelongsToTheStoreThatListedIt() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feedURL = URL(string: "https://stub.example/\(UUID().uuidString)/api")!
        let catalog = AppCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session(),
            feedURL: feedURL
        )
        Self.answerHomeFeeds(base: feedURL, title: "Row")

        let rebble = try await catalog.update(model: nil, source: .rebble).applications[0]
        #expect(rebble.sourceID == "rebble")
        #expect(rebble.storePageURL?.absoluteString
            == "https://apps.rebble.io/application/5f1e2d3c4b5a697887654321")

        let pebble = try await catalog.update(model: nil, source: .pebble).applications[0]
        #expect(pebble.storePageURL?.absoluteString
            == "https://apps.repebble.com/5f1e2d3c4b5a697887654321")

        var legacy = pebble
        legacy.sourceID = nil
        #expect(legacy.storePageURL?.absoluteString
            == "https://apps.repebble.com/5f1e2d3c4b5a697887654321")
    }

    /// A source that publishes no index cannot be searched past its shop
    /// window; the refusal reads as the failure banner, not as empty results.
    @Test func aSourceWithoutAnIndexRefusesToSearch() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = AppCatalog(
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

        await #expect(throws: AppCatalogError.invalidResponse) {
            _ = try await catalog.search("mario", source: indexless)
        }
    }
}
