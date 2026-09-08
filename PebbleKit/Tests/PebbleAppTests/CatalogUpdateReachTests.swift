import Foundation
import Synchronization
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// Which applications Update All can see.
///
/// It used to read the loaded feed and filter it, and that feed is
/// `v1/home` — a page of what the store is featuring, 73 applications the day
/// this was written. An application installed from anywhere else was never
/// offered an update, however far behind it had fallen, and nothing said so.
@Suite
@MainActor
struct CatalogUpdateReachTests {
    /// One store and one installed application, belonging to one test.
    ///
    /// The stub is reached through a static table, and tests run at the same
    /// time, so two of these sharing an address would answer each other's
    /// lookups — which is exactly how the first draft of this file passed a
    /// test it should have failed.
    private struct Fixture {
        let base: URL
        let installedID: UUID

        init() {
            let token = UUID().uuidString.lowercased()
            self.base = URL(string: "https://store-\(token).invalid/api")!
            self.installedID = UUID()
        }

        var lookupURL: URL {
            base.appending(path: "v1/apps/uuid").appending(path: installedID.uuidString.lowercased())
        }

        func storeAnswer(version: String) -> Data {
            Data("""
            {
              "data": [
                {
                  "author": "Keynes",
                  "category": "Tools & Utilities",
                  "description": "Five watch utilities in one place.",
                  "id": "1b25cef73e2b471686672d07",
                  "title": "Watch Tools",
                  "type": "watchapp",
                  "uuid": "\(installedID.uuidString.lowercased())",
                  "hardware_platforms": [{"name": "emery"}],
                  "latest_release": {
                    "pbw_file": "https://store.invalid/watch-tools.pbw",
                    "version": "\(version)"
                  }
                }
              ]
            }
            """.utf8)
        }

        /// A feed with something in it, but not this application — the shape
        /// of the real one.
        var snapshotWithoutTheInstalledApplication: CatalogSnapshot {
            CatalogSnapshot(
                sourceURL: base,
                fetchedAt: Date(timeIntervalSince1970: 100),
                applications: [
                    CatalogApplication(
                        id: UUID(),
                        storeID: "aaaaaaaaaaaaaaaaaaaaaaaa",
                        name: "Something Featured",
                        developer: "Somebody",
                        version: "9.0",
                        downloadURL: URL(string: "https://store.invalid/featured.pbw")!,
                        supportedPlatforms: ["emery"]
                    )
                ]
            )
        }

        func installedApplication(version: String) -> WatchApplication {
            WatchApplication(
                id: installedID,
                shortName: "Tools",
                longName: "Watch Tools",
                companyName: "Keynes",
                versionCode: 1,
                versionLabel: version,
                capabilities: [],
                targetPlatforms: ["emery"],
                kind: .watchapp
            )
        }
    }

    /// A model whose library holds one application and whose catalogue was
    /// fetched from a store that does not list it in its feed.
    private func makeModel(
        _ fixture: Fixture,
        directory: URL,
        installedVersion: String
    ) async throws -> AppModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cacheURL = directory.appending(path: "catalog.json")
        try JSONEncoder()
            .encode(fixture.snapshotWithoutTheInstalledApplication)
            .write(to: cacheURL, options: .atomic)

        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        _ = try await library.upsert(fixture.installedApplication(version: installedVersion))

        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            appCatalog: AppCatalog(cacheURL: cacheURL, session: StoreStubURLProtocol.session())
        )
        await model.loadApplications()
        await model.loadCatalog()
        return model
    }

    /// The regression. The feed does not have it; the store does, and says the
    /// version is newer than the one installed.
    @Test func anApplicationOutsideTheFeedIsStillOfferedItsUpdate() async throws {
        let fixture = Fixture()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        StoreStubURLProtocol.answer(fixture.lookupURL, with: fixture.storeAnswer(version: "2.0"))
        let model = try await makeModel(fixture, directory: directory, installedVersion: "1.0")
        // It really is absent from what the feed loaded, which is what used to
        // make it invisible here.
        #expect(!model.catalog.applications.contains { $0.id == fixture.installedID })

        let updates = await model.catalogUpdates()

        #expect(updates.map(\.id) == [fixture.installedID])
        #expect(updates.first?.version == "2.0")
    }

    /// And the same application when it is already current: found, compared,
    /// and left alone. Without this the test above would pass on a version
    /// comparison that had stopped happening.
    @Test func anApplicationOutsideTheFeedThatIsCurrentIsLeftAlone() async throws {
        let fixture = Fixture()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        StoreStubURLProtocol.answer(fixture.lookupURL, with: fixture.storeAnswer(version: "2.0"))
        let model = try await makeModel(fixture, directory: directory, installedVersion: "2.0")

        #expect(await model.catalogUpdates().isEmpty)
    }

    /// A package the store never listed. Asked about, answered 404, and not
    /// mistaken for something to update.
    @Test func anApplicationTheStoreNeverListedIsNotAnUpdate() async throws {
        let fixture = Fixture()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Nothing registered for this fixture's lookup, so the stub answers 404.
        let model = try await makeModel(fixture, directory: directory, installedVersion: "1.0")

        #expect(await model.catalogUpdates().isEmpty)
    }
}

/// Whether an installed release is current, judged against the right number.
///
/// The store's `version` and the package's `versionLabel` are not the same
/// fact, and measured across the whole feed they disagree on three releases of
/// thirty-one — a `2.1-rbl1` over a `2.1`, a `1.3.0` over a `1.3`, and a
/// `1.2.6` whose package itself says `1.2.5`. Judged against the label, each
/// was an update forever, freshly installed or not (#117).
@Suite
@MainActor
struct CatalogUpdateLoopTests {
    private func makeModel(directory: URL, installed: WatchApplication) async throws -> AppModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        _ = try await library.upsert(installed)
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library
        )
        await model.loadApplications()
        return model
    }

    private func storeEntry(id: UUID, version: String) -> CatalogApplication {
        CatalogApplication(
            id: id,
            storeID: "aaaaaaaaaaaaaaaaaaaaaaaa",
            name: "Timer",
            developer: "Somebody",
            version: version,
            downloadURL: URL(string: "https://store.invalid/timer.pbw")!,
            supportedPlatforms: ["emery"]
        )
    }

    private func installed(id: UUID, label: String, storeVersion: String?) -> WatchApplication {
        WatchApplication(
            id: id,
            shortName: "Timer",
            longName: "Timer",
            companyName: "Somebody",
            versionCode: 1,
            versionLabel: label,
            capabilities: [],
            targetPlatforms: ["emery"],
            kind: .watchapp,
            storeVersion: storeVersion
        )
    }

    /// The worst of the three measured: the store says 1.2.6 and the package
    /// inside says 1.2.5, so no reading of the label can ever be current.
    /// Remembering which store release was installed is what settles it.
    @Test func aReleaseWhosePackageDisagreesWithTheStoreIsStillCurrent() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let model = try await makeModel(
            directory: directory,
            installed: installed(id: id, label: "1.2.5", storeVersion: "1.2.6")
        )

        #expect(model.catalogInstallationState(for: storeEntry(id: id, version: "1.2.6")) == .installed)
        // And a release the store has actually moved past is still an update.
        #expect(model.catalogInstallationState(for: storeEntry(id: id, version: "1.2.7")) == .updateAvailable)
    }

    /// A package that came in as a file has no store release to remember, and
    /// its label is the only version anybody has.
    @Test func aFileImportIsStillJudgedByItsOwnLabel() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let model = try await makeModel(
            directory: directory,
            installed: installed(id: id, label: "1.3", storeVersion: nil)
        )

        #expect(model.catalogInstallationState(for: storeEntry(id: id, version: "1.3")) == .installed)
        #expect(model.catalogInstallationState(for: storeEntry(id: id, version: "1.3.0")) == .updateAvailable)
    }

    /// The field is new and optional, so a library written before it exists
    /// still opens — with no remembered store release, which is the truth.
    @Test func anOldLibraryFileDecodesWithNoStoreVersion() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","shortName":"Old","longName":"Old","companyName":"C",
          "versionLabel":"1.0","capabilities":[],"targetPlatforms":["emery"],
          "kind":"watchapp","appKeys":{},"hasCompanionJavaScript":false}]
        """
        let decoded = try JSONDecoder().decode([WatchApplication].self, from: Data(json.utf8))

        #expect(decoded.first?.storeVersion == nil)
        #expect(decoded.first?.versionLabel == "1.0")
    }
}
