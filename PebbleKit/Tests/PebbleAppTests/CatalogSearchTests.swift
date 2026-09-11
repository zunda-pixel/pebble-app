import Foundation
import PebbleTransport
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Searching the store's whole index rather than sifting the fetched home
/// feed (#97).
@MainActor
@Suite
struct CatalogSearchTests {
    private static func hit(
        uuid: String = "A1A1A1A1-0000-0000-0000-000000000001",
        id: String = "5f1e2d3c4b5a697887654321",
        title: String? = "Mario Time",
        pbw: String? = "https://store.example/mario.pbw",
        type: String = "watchface",
        compatibility: String = """
        {"ios": {"supported": true}, "android": {"supported": true},
         "aplite": {"supported": false}, "basalt": {"supported": true},
         "emery": {"supported": true}}
        """
    ) -> String {
        """
        {
            "title": \(title.map { "\"\($0)\"" } ?? "null"),
            "author": "tribute",
            "uuid": "\(uuid)",
            "id": "\(id)",
            "type": "\(type)",
            "category": "Faces",
            "description": "It's-a me",
            "version": "3.1",
            "icon_image": "https://store.example/icon.png",
            "screenshot_images": ["https://store.example/one.png"],
            "latest_release": \(pbw.map { "{\"pbw_file\": \"\($0)\"}" } ?? "null"),
            "compatibility": \(compatibility)
        }
        """
    }

    private static func page(hits: [String], page: Int = 0, pages: Int = 1, total: Int? = nil) -> Data {
        Data("""
        {"hits": [\(hits.joined(separator: ","))],
         "page": \(page), "nbPages": \(pages), "nbHits": \(total ?? hits.count)}
        """.utf8)
    }

    /// Each test gets an index address of its own: the stub answers by URL and
    /// is shared by every test running beside this one.
    private func catalog(in directory: URL, searchURL: URL) -> AppCatalog {
        AppCatalog(
            cacheURL: directory.appending(path: "catalog.json"),
            session: StoreStubURLProtocol.session(),
            searchURL: searchURL
        )
    }

    private static func uniqueSearchURL() -> URL {
        URL(string: "https://stub.example/\(UUID().uuidString)/query")!
    }

    @Test func aHitBecomesACatalogApplicationTheInstallPathCanUse() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchURL = Self.uniqueSearchURL()
        StoreStubURLProtocol.answer(searchURL, with: Self.page(hits: [Self.hit()]))

        let answer = try await catalog(in: directory, searchURL: searchURL).search("mario", kind: .watchface)

        let application = try #require(answer.applications.first)
        #expect(application.name == "Mario Time")
        #expect(application.developer == "tribute")
        #expect(application.storeID == "5f1e2d3c4b5a697887654321")
        #expect(application.version == "3.1")
        #expect(application.kind == .watchface)
        #expect(application.downloadURL.absoluteString == "https://store.example/mario.pbw")
        // The phone platforms are not boards, and an unsupported board is not
        // a supported one.
        #expect(application.supportedPlatforms == ["basalt", "emery"])
        #expect(application.category == "Faces")
        #expect(answer.hasMore == false)
    }

    /// One hit this app cannot use costs that hit, not the page it arrived in.
    @Test func aHitWithNoDownloadOrNoTitleIsDroppedAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchURL = Self.uniqueSearchURL()
        StoreStubURLProtocol.answer(searchURL, with: Self.page(hits: [
            Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000001"),
            Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000002", pbw: nil),
            Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000003", title: nil),
        ]))

        let answer = try await catalog(in: directory, searchURL: searchURL).search("mario")

        #expect(answer.applications.count == 1)
    }

    @Test func moreResultsAppendWithoutDoublingARow() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let searchURL = Self.uniqueSearchURL()
        let client = MockWatchClient()
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: catalog(in: directory, searchURL: searchURL)
        )

        StoreStubURLProtocol.answer(searchURL, with: Self.page(
            hits: [Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000001")],
            page: 0, pages: 2, total: 3
        ))
        await model.searchCatalog("mario")
        #expect(model.catalog.searchResults?.count == 1)
        #expect(model.catalog.hasMoreSearchResults)

        // The second page arrives with the first row again — the index can
        // shift under the pages — and with one new one.
        StoreStubURLProtocol.answer(searchURL, with: Self.page(
            hits: [
                Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000001"),
                Self.hit(uuid: "A1A1A1A1-0000-0000-0000-000000000002"),
            ],
            page: 1, pages: 2, total: 3
        ))
        await model.loadMoreCatalogSearchResults()

        #expect(model.catalog.searchResults?.count == 2)
        #expect(model.catalog.hasMoreSearchResults == false)

        model.clearCatalogSearch()
        #expect(model.catalog.searchResults == nil)
    }

    /// A failed search says so where the reader is, and leaves the home feed
    /// alone.
    @Test func aSearchTheStoreRefusesIsAFailureAndNothingMore() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: catalog(in: directory, searchURL: Self.uniqueSearchURL())
        )
        // Nothing registered for the search URL: the stub answers 404.

        await model.searchCatalog("mario")

        #expect(model.catalog.searchResults == nil)
        #expect(model.catalog.feedback?.isFailure == true)
    }

    /// A blank search is not a question, and whitespace is not words.
    @Test func aBlankSearchAsksNothing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            appCatalog: catalog(in: directory, searchURL: Self.uniqueSearchURL())
        )

        await model.searchCatalog("   ")

        #expect(model.catalog.searchResults == nil)
        #expect(model.catalog.feedback == nil)
    }
}
