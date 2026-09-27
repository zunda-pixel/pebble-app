import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// What a synchronization writes to a watch's application database.
@Suite
@MainActor
struct ApplicationSynchronizationTests {
    private struct Fixture {
        var model: AppModel
        var client: MockWatchClient
        var library: WatchApplicationLibrary
        var directory: URL
        var watch: DiscoveredWatch
        var applicationIDs: [UUID]
    }

    /// Two watch apps in the library, and a Pebble Time 2 connected and
    /// synchronized with them.
    private func connectedFixture() async throws -> Fixture {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = MockWatchClient()
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let applicationIDs = [UUID(), UUID()]
        for applicationID in applicationIDs {
            let package = try makeApplicationPackage(in: directory, applicationID: applicationID, versionLabel: "1.0")
            model.updateApplications(try await library.importPackage(from: package))
        }
        await model.scan()
        let watch = try #require(model.discoveredWatches.first { $0.model == .pebbleTime2 })
        await model.connect(to: watch)
        return Fixture(
            model: model,
            client: client,
            library: library,
            directory: directory,
            watch: watch,
            applicationIDs: applicationIDs
        )
    }

    @Test func aSecondSynchronizationWritesNoRegistration() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        #expect(Set(fixture.client.applicationRegistrationWrites) == Set(fixture.applicationIDs))
        let connection = try #require(fixture.model.activeConnections.first)

        await fixture.model.synchronizeApplications(on: connection)

        #expect(fixture.client.applicationRegistrationWrites.count == 2)
        #expect(fixture.client.reorderedApplicationIDs.count == 2)
    }

    @Test func reconnectingAFaithfulWatchWritesNoRegistration() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.model.disconnect(watchID: fixture.watch.id)
        await fixture.model.connect(to: fixture.watch)

        #expect(fixture.client.applicationRegistrationWrites.count == 2)
    }

    @Test func reorderingWritesNoRegistration() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let before = fixture.client.reorderedApplicationIDs.count

        await fixture.model.reorderApplications(kind: .watchapp, fromOffsets: IndexSet(integer: 0), toOffset: 2)

        #expect(fixture.client.applicationRegistrationWrites.count == 2)
        #expect(fixture.client.reorderedApplicationIDs.count == before + 1)
        #expect(fixture.client.reorderedApplicationIDs.last == fixture.applicationIDs.reversed())
    }

    @Test func importingWritesOnlyThatApplication() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let imported = UUID()
        let package = try makeApplicationPackage(in: fixture.directory, applicationID: imported, versionLabel: "1.0")

        #expect(await fixture.model.importApplication(from: package))

        #expect(fixture.client.applicationRegistrationWrites.dropFirst(2) == [imported])
    }

    /// The same registration can stand in front of a different binary, and only
    /// a fresh one makes the watch let go of the binary it has cached.
    @Test func importingOverAnApplicationWritesItAgain() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let replaced = fixture.applicationIDs[0]
        let package = try makeApplicationPackage(in: fixture.directory, applicationID: replaced, versionLabel: "1.1")

        #expect(await fixture.model.importApplication(from: package))

        #expect(fixture.client.applicationRegistrationWrites.dropFirst(2) == [replaced])
    }

    @Test func anUnfaithfulWatchIsGivenEverythingAgain() async throws {
        let fixture = try await connectedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await fixture.model.disconnect(watchID: fixture.watch.id)
        fixture.client.connectsAsUnfaithful = true
        await fixture.model.connect(to: fixture.watch)

        #expect(Set(fixture.client.applicationRegistrationWrites.dropFirst(2)) == Set(fixture.applicationIDs))
    }
}
