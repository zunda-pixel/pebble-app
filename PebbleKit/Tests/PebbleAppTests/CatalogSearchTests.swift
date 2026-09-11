import Foundation
import PebbleTransport
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Searching the store's whole index rather than sifting the fetched home
/// feed (#97).
///
/// Two round trips, the way the live services actually answer (measured
/// 2026-09-11): the index returns rankings without a release, so the hits'
/// identifiers are resolved against the feed's bulk endpoint, which returns
/// the same full entries the home feed is made of.
@MainActor
@Suite
struct CatalogSearchTests {
    private static func hit(id: String) -> String { "{\"id\": \"\(id)\"}" }

    private static func searchPage(ids: [String], page: Int = 0, pages: Int = 1, total: Int? = nil) -> Data {
        Data("""
        {"hits": [\(ids.map(hit(id:)).joined(separator: ","))],
         "page": \(page), "nbPages": \(pages), "nbHits": \(total ?? ids.count)}
        """.utf8)
    }

    /// A full feed entry, in the same shape `v1/apps/bulk` answers with.
    private static func entry(
        id: String,
        uuid: String,
        title: String? = "Mario Time",
        pbw: String? = "https://store.example/mario.pbw"
    ) -> String {
        """
        {
            "id": "\(id)",
            "uuid": "\(uuid)",
            "title": \(title.map { "\"\($0)\"" } ?? "null"),
            "author": "tribute",
            "type": "watchface",
            "category": "Faces",
            "description": "It's-a me",
            "hardware_platforms": [{"name": "basalt"}, {"name": "emery"}],
            "icon_image": {"48x48": "https://store.example/icon.png"},
            "screenshot_images": [{"144x168": "https://store.example/one.png"}],
            "latest_release": \(pbw.map { "{\"pbw_file\": \"\($0)\", \"version\": \"3.1\"}" } ?? "null")
        }
        """
    }

    private static func bulk(_ entries: [String]) -> Data {
        Data("{\"data\": [\(entries.joined(separator: ","))]}".utf8)
    }

    /// Each test gets addresses of its own: the stub answers by URL and is
    /// shared by every test running beside this one.
    private struct Stub {
        let searchURL = URL(string: "https://stub.example/\(UUID().uuidString)/query")!
        let feedURL = URL(string: "https://stub.example/\(UUID().uuidString)/api")!
        var bulkURL: URL { feedURL.appending(path: "v1/apps/bulk") }

        func catalog(in directory: URL) -> AppCatalog {
            AppCatalog(
                cacheURL: directory.appending(path: "catalog.json"),
                session: StoreStubURLProtocol.session(),
                searchURL: searchURL,
                feedURL: feedURL
            )
        }
    }

    @Test func aHitIsResolvedThroughTheFeedIntoAnInstallableRow() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        StoreStubURLProtocol.answer(stub.searchURL, with: Self.searchPage(ids: ["mario-id"]))
        StoreStubURLProtocol.answer(stub.bulkURL, with: Self.bulk([
            Self.entry(id: "mario-id", uuid: "A1A1A1A1-0000-0000-0000-000000000001")
        ]))

        let answer = try await stub.catalog(in: directory).search("mario", kind: .watchface)

        let application = try #require(answer.applications.first)
        #expect(application.name == "Mario Time")
        #expect(application.developer == "tribute")
        #expect(application.storeID == "mario-id")
        #expect(application.version == "3.1")
        #expect(application.kind == .watchface)
        #expect(application.downloadURL.absoluteString == "https://store.example/mario.pbw")
        #expect(application.supportedPlatforms == ["basalt", "emery"])
        #expect(application.category == "Faces")
        #expect(answer.hasMore == false)
    }

    /// The feed's answer comes back in the server's own order and in the
    /// index's ranking it goes; an entry the feed cannot answer for — or one
    /// with no release to install — costs its row alone.
    @Test func theIndexOrderIsKeptAndAnUnanswerableRowIsDroppedAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        StoreStubURLProtocol.answer(stub.searchURL, with: Self.searchPage(ids: ["first", "gone", "broken", "second"]))
        StoreStubURLProtocol.answer(stub.bulkURL, with: Self.bulk([
            // The server answers out of order, without "gone", and with
            // "broken" lacking a release.
            Self.entry(id: "second", uuid: "A1A1A1A1-0000-0000-0000-000000000002", title: "Second"),
            Self.entry(id: "broken", uuid: "A1A1A1A1-0000-0000-0000-000000000003", pbw: nil),
            Self.entry(id: "first", uuid: "A1A1A1A1-0000-0000-0000-000000000001", title: "First"),
        ]))

        let answer = try await stub.catalog(in: directory).search("mario")

        #expect(answer.applications.map(\.name) == ["First", "Second"])
    }

    @Test func moreResultsAppendWithoutDoublingARow() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: stub.catalog(in: directory)
        )

        StoreStubURLProtocol.answer(stub.searchURL, with: Self.searchPage(
            ids: ["one"], page: 0, pages: 2, total: 3
        ))
        StoreStubURLProtocol.answer(stub.bulkURL, with: Self.bulk([
            Self.entry(id: "one", uuid: "A1A1A1A1-0000-0000-0000-000000000001")
        ]))
        await model.searchCatalog("mario")
        #expect(model.catalog.searchResults?.count == 1)
        #expect(model.catalog.hasMoreSearchResults)

        // The second page arrives with the first row again — the index can
        // shift under the pages — and with one new one.
        StoreStubURLProtocol.answer(stub.searchURL, with: Self.searchPage(
            ids: ["one", "two"], page: 1, pages: 2, total: 3
        ))
        StoreStubURLProtocol.answer(stub.bulkURL, with: Self.bulk([
            Self.entry(id: "one", uuid: "A1A1A1A1-0000-0000-0000-000000000001"),
            Self.entry(id: "two", uuid: "A1A1A1A1-0000-0000-0000-000000000002", title: "Luigi Time"),
        ]))
        await model.loadMoreCatalogSearchResults()

        #expect(model.catalog.searchResults?.count == 2)
        #expect(model.catalog.hasMoreSearchResults == false)

        model.clearCatalogSearch()
        #expect(model.catalog.searchResults == nil)
    }

    /// A failed search says so where the reader is, and leaves the home feed
    /// alone. Nothing is registered at either stub address: the index answers
    /// 404.
    @Test func aSearchTheStoreRefusesIsAFailureAndNothingMore() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: stub.catalog(in: directory)
        )

        await model.searchCatalog("mario")

        #expect(model.catalog.searchResults == nil)
        #expect(model.catalog.feedback?.isFailure == true)
    }

    /// A blank search is not a question, and whitespace is not words.
    @Test func aBlankSearchAsksNothing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = Stub()
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: stub.catalog(in: directory)
        )

        await model.searchCatalog("   ")

        #expect(model.catalog.searchResults == nil)
        #expect(model.catalog.feedback == nil)
    }
}
