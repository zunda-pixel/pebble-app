import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Which applications the catalogue's pickers leave on screen.
///
/// The category picker used the string `"All"` for three things at once: the
/// row's label, the initial selection, and the mark meaning "do not filter".
/// That put an English word on a Japanese screen — `Text(_:)` given a `String`
/// is the overload that does not localize, and a plain `String` is never
/// extracted into the catalogue, so the localization test could not see it —
/// and it made a category genuinely named All the one category nobody could
/// filter by. The store is free to send that name; nothing stops it.
@Suite
struct CatalogFilterTests {
    private func application(
        name: String,
        category: String?,
        kind: WatchApplicationKind = .watchapp
    ) -> CatalogApplication {
        CatalogApplication(
            id: UUID(),
            storeID: name.lowercased(),
            name: name,
            developer: "Someone",
            version: "1.0",
            downloadURL: URL(string: "https://example.invalid/\(name).pbw")!,
            supportedPlatforms: ["emery"],
            kind: kind,
            category: category,
            summary: nil
        )
    }

    /// The fault the sentinel caused, and the reason it is a missing value now.
    @Test func aCategoryTheStoreNamedAllCanBeFilteredBy() {
        let applications = [
            application(name: "Orbit", category: "All"),
            application(name: "Tide", category: "Games"),
        ]

        // Asking for the category named All gives the one application in it,
        // not every application. With the sentinel this returned both.
        let inAll = CatalogFilter(category: "All").applied(to: applications)
        #expect(inAll.map(\.name) == ["Orbit"])

        // And nil still means every one of them.
        let everything = CatalogFilter(category: nil).applied(to: applications)
        #expect(everything.count == 2)
    }

    /// An application the store did not put in a category.
    ///
    /// It used to carry this app's own `"Other"`, which meant it appeared under
    /// a category the store had never heard of and could be filtered by that
    /// invented name. Now it has none, and is only reachable with no filter.
    @Test func anApplicationWithNoCategoryIsShownButOffersNoCategory() {
        let applications = [
            application(name: "Orbit", category: nil),
            application(name: "Tide", category: "Games"),
        ]

        #expect(CatalogFilter(category: nil).applied(to: applications).count == 2)
        #expect(CatalogFilter(category: "Games").applied(to: applications).map(\.name) == ["Tide"])
        // Nothing named it, so it is not one of the rows to pick from.
        #expect(CatalogFilter.categories(in: applications) == ["Games"])
        // And "Other" is not a category anyone can ask for.
        #expect(CatalogFilter(category: "Other").applied(to: applications).isEmpty)
    }

    /// The store's own words stay the store's own, and stay pickable.
    @Test func theStoresCategoriesAreOfferedInOrderAndWithoutDuplicates() {
        let applications = [
            application(name: "Orbit", category: "Tools & Utilities"),
            application(name: "Tide", category: "Games"),
            application(name: "Ripple", category: "Games"),
            application(name: "Plain", category: nil),
        ]

        #expect(CatalogFilter.categories(in: applications) == ["Games", "Tools & Utilities"])
    }

    /// The other two pickers still work through the same predicate.
    @Test func theCategoryFilterCombinesWithTheKindAndTheQuery() {
        let applications = [
            application(name: "Orbit", category: "Games", kind: .watchapp),
            application(name: "Orbit Face", category: "Games", kind: .watchface),
            application(name: "Tide", category: "Games", kind: .watchapp),
        ]

        let faces = CatalogFilter(category: "Games", kind: .watchfaces).applied(to: applications)
        #expect(faces.map(\.name) == ["Orbit Face"])

        let searched = CatalogFilter(query: "orbit", category: "Games").applied(to: applications)
        #expect(searched.map(\.name) == ["Orbit", "Orbit Face"])
    }
}
