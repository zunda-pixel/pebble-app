import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// What the reader is told about importing a package from a file.
///
/// They were told nothing. The `Import` button lives on the catalogue screen,
/// which is pushed over the applications screen, and the applications screen is
/// where the answer was drawn — so a failed import showed a spinner that
/// vanished and left no message anywhere the reader was looking (#110).
@Suite
@MainActor
struct ApplicationImportFeedbackTests {
    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Measured before deciding where to draw the progress bar: there is none to
    /// draw while a package is being imported.
    ///
    /// `beginTransfer` is called from `handleAppFetchRequest` and nowhere else,
    /// and the watch only sends that once it tries to run the app. Importing
    /// registers the application and asks the watch to launch it; the bytes go
    /// later, if at all. So the fix for #110 is about the answer, not the bar.
    ///
    /// The transfer that does eventually happen is `PendingWorkTests`' to
    /// exercise: it drives `handleAppFetchRequest` end to end.
    @Test func importingDoesNotStartATransferToShowProgressFor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let package = try makeApplicationPackage(
            in: directory,
            applicationID: UUID(),
            versionLabel: "1.0"
        )

        await model.importApplication(from: package)

        #expect(model.applicationTransfer(on: discovered.id) == nil)
    }

    /// The answer to importing goes where the import was asked for.
    /// Success is silent: the row appearing in the library says it, and a
    /// banner only repeated it. A failure is the one thing worth a banner.
    @Test func anImportThatWorkedSaysNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        let package = try makeApplicationPackage(
            in: directory,
            applicationID: UUID(),
            versionLabel: "1.0"
        )

        await model.importApplication(from: package)

        #expect(model.applications.importFeedback == nil)
    }

    @Test func anImportThatFailedSaysSoWhereTheButtonIs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        // Not a package at all, which the importer refuses before any watch is
        // involved.
        let notAPackage = directory.appending(path: "notes.pbw")
        try Data("this is not a zip".utf8).write(to: notAPackage)

        await model.importApplication(from: notAPackage)

        #expect(model.applications.importFeedback?.isFailure == true)
    }

    /// Its own field, so that the catalogue screen showing it does not also show
    /// the answer to removing an app or activating a watchface.
    @Test func importingDoesNotAnswerOnBehalfOfTheRestOfTheLibrary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        let notAPackage = directory.appending(path: "notes.pbw")
        try Data("this is not a zip".utf8).write(to: notAPackage)

        await model.importApplication(from: notAPackage)

        #expect(model.applications.libraryFeedback == nil)
    }
}
