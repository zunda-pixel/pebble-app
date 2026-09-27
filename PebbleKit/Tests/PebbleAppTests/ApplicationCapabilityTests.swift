import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// What an application says it uses, as the detail screen reads it.
///
/// The package has carried these since the importer was written and nothing
/// looked at them, so the screen showed a settings button and a JavaScript
/// label and said nothing about health, location or the timeline (#104).
@Suite
struct ApplicationCapabilityTests {
    private func application(capabilities: [String]) -> WatchApplication {
        WatchApplication(
            id: UUID(),
            shortName: "Orbit",
            longName: "Orbit",
            companyName: "Pebble",
            versionLabel: "1.0",
            capabilities: capabilities,
            targetPlatforms: [.emery],
            kind: .watchapp
        )
    }

    private func storeRow(capabilities: [String]) -> CatalogApplication {
        CatalogApplication(
            id: UUID(),
            name: "Orbit",
            developer: "Pebble",
            version: "1.0",
            downloadURL: URL(string: "https://example.invalid/orbit.pbw")!,
            supportedPlatforms: [.emery],
            kind: .watchapp,
            capabilities: capabilities
        )
    }

    /// Always in the same order, so two applications can be compared by eye.
    @Test func theKnownOnesAreListedInOneOrderWhateverOrderTheyArrivedIn() {
        #expect(
            WatchApplicationCapability.declared(in: ["timeline", "location", "health"])
                == [.health, .location, .timeline]
        )
    }

    /// `configurable` is the settings button, not something asked of the phone.
    @Test func configurableIsNotOneOfThem() {
        #expect(WatchApplicationCapability.declared(in: ["configurable"]).isEmpty)
        #expect(
            WatchApplicationCapability.declared(in: ["configurable", "health"]) == [.health]
        )
    }

    /// Kept rather than dropped: the store adds codes on its own schedule.
    @Test func aCodeThisAppDoesNotKnowIsKeptAndShownAsItself() {
        let declared = WatchApplicationCapability.declared(in: ["sport", "health"])

        #expect(declared == [.health, .other("sport")])
        #expect(declared.map(\.code) == ["health", "sport"])
    }

    /// The package describes the copy that will actually run.
    @Test func thePackageWinsOverTheStoreRow() {
        let subject = ApplicationDetailSubject(
            installed: application(capabilities: ["health"]),
            catalogEntry: storeRow(capabilities: ["location", "timeline"])
        )

        #expect(subject.capabilities == [.health])
    }

    /// Until there is a package, the store's row is all there is.
    @Test func theStoreRowIsUsedForSomethingNotInstalled() {
        let subject = ApplicationDetailSubject(
            catalogEntry: storeRow(capabilities: ["location"]),
            installed: nil
        )

        #expect(subject.capabilities == [.location])
    }

    /// A package that declares nothing is not the same as a package that was
    /// never asked: the store still gets to say.
    @Test func aPackageThatDeclaresNothingLetsTheStoreSpeak() {
        let subject = ApplicationDetailSubject(
            installed: application(capabilities: ["configurable"]),
            catalogEntry: storeRow(capabilities: ["timeline"])
        )

        #expect(subject.capabilities == [.timeline])
    }

    /// The store sends this at the top level of an entry; a row written before
    /// this app read it decodes to empty rather than failing.
    @Test func theStoresOwnFieldIsReadAndAMissingOneIsNotAnError() throws {
        let entry = Data("""
        {
          "uuid": "1F0B0B5A-0000-4000-8000-000000000001",
          "title": "Orbit",
          "author": "Pebble",
          "capabilities": ["location", "configurable"],
          "latest_release": { "pbw_file": "https://example.invalid/orbit.pbw", "version": "1.0" }
        }
        """.utf8)
        let withoutField = Data("""
        {
          "uuid": "1F0B0B5A-0000-4000-8000-000000000002",
          "title": "Orbit",
          "author": "Pebble",
          "latest_release": { "pbw_file": "https://example.invalid/orbit.pbw", "version": "1.0" }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(OfficialCatalogApplication.self, from: entry)
        let bare = try JSONDecoder().decode(OfficialCatalogApplication.self, from: withoutField)

        #expect(try #require(decoded.application(kind: .watchapp)).declaredCapabilities == [.location])
        #expect(try #require(bare.application(kind: .watchapp)).declaredCapabilities.isEmpty)
    }
}
