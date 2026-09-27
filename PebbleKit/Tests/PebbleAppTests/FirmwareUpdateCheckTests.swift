import Defaults
import Foundation
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// The connect-time firmware check, which tells the phone about an update
/// instead of waiting for the reader to ask (#102).
///
/// Serialised for the same reason the charge suite is: the switches live in
/// `Defaults`, which the test process shares.
@Suite(.serialized)
@MainActor
struct FirmwareUpdateCheckTests {
    /// One GitHub releases address per test, answered by the stub — the same
    /// isolation trick `CatalogUpdateReachTests` uses.
    private struct Fixture {
        let releasesURL: URL

        init() {
            let token = UUID().uuidString.lowercased()
            releasesURL = URL(string: "https://github-\(token).invalid/releases/latest")!
        }

        /// The mock's first discovered watch is a Pebble 2 Duo running
        /// `v5.0.0-mock`, whose board is asterix.
        func publish(version: String) {
            StoreStubURLProtocol.answer(releasesURL, with: Data("""
            [{
              "tag_name": "\(version)",
              "html_url": "https://example.invalid/notes",
              "assets": [
                {
                  "name": "normal_asterix_\(version).pbz",
                  "size": 1000,
                  "browser_download_url": "https://example.invalid/firmware.pbz"
                }
              ]
            }]
            """.utf8))
        }
    }

    private func makeModel(
        directory: URL,
        fixture: Fixture,
        notifier: SpyNotifier
    ) -> AppModel {
        AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            localNotifier: notifier,
            firmwareCatalog: PebbleOSFirmwareCatalog(
                releasesURL: fixture.releasesURL,
                session: StoreStubURLProtocol.session()
            )
        )
    }

    /// Instance state rather than `Defaults`, for the same reason the charge
    /// suite avoids the stored key: it is process-global, and holding it true
    /// here would send every concurrently running suite's model to the real
    /// firmware catalogue. The announcement memory is still the stored one,
    /// so it is cleared around each test.
    private func withSwitchOn(_ model: AppModel, _ body: () async throws -> Void) async rethrows {
        model.notifyAboutFirmwareUpdatesEnabled = true
        Defaults[.notifiedFirmwareVersions] = [:]
        defer { Defaults[.notifiedFirmwareVersions] = [:] }
        try await body()
    }

    @Test func aNewerReleaseIsAnnouncedOnceAcrossConnects() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        fixture.publish(version: "v5.1.0")
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, fixture: fixture, notifier: notifier)

        try await withSwitchOn(model) {
            await model.scan()
            await model.connect(to: try #require(model.discoveredWatches.first))
            let connection = try #require(model.activeConnections.first)

            #expect(notifier.posted.count == 1)
            #expect(notifier.posted.first?.body.contains("v5.1.0") == true)
            #expect(notifier.posted.first?.body.contains(connection.watch.name) == true)

            // The same release again is not news — even past the check cache.
            model.firmwareCheckedAt = [:]
            await model.checkFirmwareUpdateUnattended(on: connection)
            #expect(notifier.posted.count == 1)
        }
    }

    @Test func aReleaseNoNewerThanTheRunningFirmwareSaysNothing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        fixture.publish(version: "v5.0.0")
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, fixture: fixture, notifier: notifier)

        try await withSwitchOn(model) {
            await model.scan()
            await model.connect(to: try #require(model.discoveredWatches.first))

            #expect(notifier.posted.isEmpty)
            // But the successful answer is cached.
            #expect(!model.firmwareCheckedAt.isEmpty)
        }
    }

    /// A network that refused is not a catalogue that answered "up to date":
    /// nothing is cached, so the next connect asks again.
    @Test func aFailedFetchCachesNothing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()   // nothing published: the stub answers 404
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, fixture: fixture, notifier: notifier)

        try await withSwitchOn(model) {
            await model.scan()
            await model.connect(to: try #require(model.discoveredWatches.first))
            let connection = try #require(model.activeConnections.first)

            #expect(model.firmwareCheckedAt.isEmpty)
            #expect(notifier.posted.isEmpty)

            // The store answers now, and the earlier failure has not silenced it.
            fixture.publish(version: "v5.2.0")
            await model.checkFirmwareUpdateUnattended(on: connection)
            #expect(notifier.posted.count == 1)
        }
    }

    @Test func nothingIsAskedWhileTheSwitchIsOff() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        fixture.publish(version: "v9.9.9")
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, fixture: fixture, notifier: notifier)
        model.notifyAboutFirmwareUpdatesEnabled = false

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        #expect(notifier.posted.isEmpty)
        #expect(model.firmwareCheckedAt.isEmpty)
    }

    @Test func theVersionComparisonStripsTheTagPrefix() {
        #expect(PebbleOSFirmwareCatalog.isVersion("v4.37.0", newerThan: "v4.36.2"))
        #expect(!PebbleOSFirmwareCatalog.isVersion("v4.36.2", newerThan: "v4.36.2"))
        #expect(!PebbleOSFirmwareCatalog.isVersion("v4.36.2", newerThan: "v4.37.0"))
        #expect(PebbleOSFirmwareCatalog.isVersion("4.37.0", newerThan: "v4.36.2"))
    }

    /// Starting the update takes its announcement down: the banner outlived
    /// its purpose the moment the transfer began.
    @Test func startingTheUpdateRemovesTheAnnouncement() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        fixture.publish(version: "v5.1.0")
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, fixture: fixture, notifier: notifier)

        try await withSwitchOn(model) {
            await model.scan()
            await model.connect(to: try #require(model.discoveredWatches.first))
            let connection = try #require(model.activeConnections.first)
            #expect(notifier.posted.count == 1)

            // The transfer path guards on a journal and throws without one;
            // the removal happens before that guard, which is the part under
            // test.
            let firmware = Data([4, 3, 2, 1])
            let package = PBZFirmwarePackage(
                manifest: PBZFirmwareManifest(
                    manifestVersion: 1,
                    firmware: PBZFirmwareBlob(
                        name: "firmware.bin",
                        type: "normal",
                        boardName: WatchBoard.obelixPVT.rawValue,
                        size: firmware.count,
                        crc: PebbleCRC32.calculate([UInt8](firmware)),
                        versionTag: "v5.1.0",
                        slot: nil
                    ),
                    resources: nil
                ),
                firmware: firmware,
                resources: nil
            )
            _ = try? await model.performFirmwareUpdate(package, on: connection)

            #expect(notifier.removed.contains(
                AppModel.firmwareNotificationIdentifier(for: connection.watch.id)
            ))
        }
    }
}
