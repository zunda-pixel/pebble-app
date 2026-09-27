import Foundation
import Testing
@testable import PebbleProtocol

/// The store's shelves — Top Picks, Most Loved — as the home feed tells them
/// and as a page of one is fetched.
@Suite
struct CatalogCollectionTests {
    @Test func theShelvesKeepTheFeedsOrderAndAHalfWrittenOneCostsItself() throws {
        let json = """
        {
          "applications": [],
          "collections": [
            {"name": "Top Picks (Changes Daily)", "slug": "top-picks",
             "links": {"apps": "/api/v1/apps/collection/top-picks/faces"}},
            {"name": "", "slug": "unnamed", "links": {"apps": "/x"}},
            {"name": "No Way In", "slug": "no-links"},
            {"name": "Most Loved", "slug": "most-loved",
             "links": {"apps": "/api/v1/apps/collection/most-loved/faces"}}
          ]
        }
        """
        let home = try JSONDecoder().decode(OfficialCatalogHome.self, from: Data(json.utf8))

        let shelves = home.catalogCollections(kind: .watchface)

        #expect(shelves.map(\.slug) == ["top-picks", "most-loved"])
        #expect(shelves.first?.name == "Top Picks (Changes Daily)")
        #expect(shelves.first?.kind == .watchface)
        #expect(shelves.first?.appsPath == "/api/v1/apps/collection/top-picks/faces")
    }

    /// The apps home and the faces home both carry a `top-picks`: two shelves,
    /// not one, and they must not collapse into each other in a list.
    @Test func theSameSlugOnBothHomesIsTwoShelves() {
        let faces = CatalogCollection(slug: "top-picks", name: "Top Picks", kind: .watchface)
        let apps = CatalogCollection(slug: "top-picks", name: "Top Picks", kind: .watchapp)

        #expect(faces.id != apps.id)
    }

    /// The shelf's path is server-relative and already carries the `/api`
    /// prefix, so it resolves against the feed's host rather than being
    /// appended to the feed's base — which would double the prefix.
    @Test func theShelfsPathResolvesAgainstTheFeedsHost() async throws {
        let catalog = ApplicationCatalog(
            cacheURL: URL.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString).json")
        )
        let collection = CatalogCollection(
            slug: "top-picks",
            name: "Top Picks",
            kind: .watchface,
            appsPath: "/api/v1/apps/collection/top-picks/faces"
        )

        let url = await catalog.collectionPageURL(
            for: collection,
            offset: 40,
            limit: 20,
            hardware: .emery,
            baseURL: URL(string: "https://appstore-api.repebble.com/api")!
        )

        let resolved = try #require(url)
        #expect(resolved.host() == "appstore-api.repebble.com")
        #expect(resolved.path() == "/api/v1/apps/collection/top-picks/faces")
        let query = URLComponents(url: resolved, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "offset", value: "40")))
        #expect(query.contains(URLQueryItem(name: "hardware", value: "emery")))
    }

    /// The store's own word decides whether there is another page.
    @Test func theNextPageLinkIsWhatSaysThereIsMore() throws {
        let more = try JSONDecoder().decode(OfficialCatalogPage.self, from: Data("""
        {"data": [], "links": {"nextPage": "/api/v1/apps/collection/all/faces?offset=20"}}
        """.utf8))
        let last = try JSONDecoder().decode(OfficialCatalogPage.self, from: Data("""
        {"data": [], "links": {"nextPage": null}}
        """.utf8))
        let bare = try JSONDecoder().decode(OfficialCatalogPage.self, from: Data("""
        {"data": []}
        """.utf8))

        #expect(more.links?.nextPage != nil)
        #expect(last.links?.nextPage == nil)
        #expect(bare.links?.nextPage == nil)
    }
}
