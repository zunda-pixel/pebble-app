import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// One application shown by one screen, whichever of the two lists reached it.
///
/// The library's `WatchApplication` and the store's `CatalogApplication`
/// describe the same thing from different sides, and an application can be in
/// either alone. What is worth pinning is which side is believed when both
/// have something to say.
@Suite
struct ApplicationDetailSubjectTests {
    private let id = UUID(uuidString: "0B202F95-BEAB-4889-B7BF-949B2EFF5C70")!

    private func installed(
        companyName: String = "Keynes",
        platforms: [String] = ["emery"]
    ) -> WatchApplication {
        WatchApplication(
            id: id,
            shortName: "Tools",
            longName: "Watch Tools",
            companyName: companyName,
            versionLabel: "1.3.0",
            capabilities: [],
            targetPlatforms: platforms,
            kind: .watchapp
        )
    }

    private func store(version: String = "1.4.0") -> CatalogApplication {
        CatalogApplication(
            id: id,
            storeID: "1b25cef73e2b471686672d07",
            name: "Watch Tools (Store)",
            developer: "Keynes on the store",
            version: version,
            downloadURL: URL(string: "https://example.invalid/tools.pbw")!,
            supportedPlatforms: ["aplite", "basalt", "emery"],
            kind: .watchapp,
            category: "Tools & Utilities",
            summary: "Five watch utilities in one place."
        )
    }

    /// The package wins for the facts both know.
    ///
    /// It describes the copy the reader has, and the store's row may be a
    /// version ahead — showing the store's `1.4.0` beside a Remove button
    /// would name a version that is not on the watch. The newer one is offered
    /// by the Update button instead.
    @Test func thePackageWinsWhereBothKnowTheSameFact() {
        let subject = ApplicationDetailSubject(installed: installed(), store: store())

        #expect(subject.version == "1.3.0")
        #expect(subject.name == "Watch Tools")
        #expect(subject.developer == "Keynes")
        #expect(subject.platforms == ["emery"])
    }

    /// And the store fills in only what a package cannot say about itself.
    @Test func theStoreAddsWhatThePackageCannotSay() {
        let subject = ApplicationDetailSubject(installed: installed(), store: store())

        #expect(subject.store?.summary == "Five watch utilities in one place.")
        #expect(subject.store?.category == "Tools & Utilities")
        #expect(subject.store?.storePageURL != nil)
    }

    /// A package may leave a field out; then the store's row is better than an
    /// empty one.
    @Test func theStoreStandsInForWhatThePackageLeftBlank() {
        let subject = ApplicationDetailSubject(
            installed: installed(companyName: "", platforms: []),
            store: store()
        )

        #expect(subject.developer == "Keynes on the store")
        #expect(subject.platforms == ["aplite", "basalt", "emery"])
    }

    /// Both ways into the screen agree. Reached from the catalogue, an
    /// application that is also installed reads exactly as it does reached from
    /// the library — otherwise the same application would have two versions and
    /// two names depending on which list was tapped.
    @Test func bothWaysInAgreeWhenTheApplicationIsInBoth() {
        let fromLibrary = ApplicationDetailSubject(installed: installed(), store: store())
        let fromCatalog = ApplicationDetailSubject(store: store(), installed: installed())

        #expect(fromLibrary == fromCatalog)
    }

    /// In the store and not installed: nothing of the library's, and the
    /// store's own version is the only one there is.
    @Test func anApplicationOnlyInTheStoreIsDescribedByTheStore() {
        let subject = ApplicationDetailSubject(store: store(), installed: nil)

        #expect(subject.installed == nil)
        #expect(subject.version == "1.4.0")
        #expect(subject.name == "Watch Tools (Store)")
        #expect(subject.platforms == ["aplite", "basalt", "emery"])
    }

    /// Installed and never listed — a package someone had as a file. The
    /// screen still has everything the package said, and simply offers no
    /// store.
    @Test func anApplicationTheStoreNeverListedStillHasItsPackage() {
        let subject = ApplicationDetailSubject(installed: installed(), store: nil)

        #expect(subject.store == nil)
        #expect(subject.name == "Watch Tools")
        #expect(subject.version == "1.3.0")
        #expect(subject.developer == "Keynes")
    }
}
