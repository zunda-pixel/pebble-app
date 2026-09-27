import Defaults
import Foundation
// `FeatureFeedback`'s words are a `LocalizedStringKey`.
import SwiftUI
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// What a screen about one watch shows is that watch's, and what a screen
/// about one application shows is that application's.
@Suite
@MainActor
struct PerWatchStateTests {
    private func makeModel(directory: URL, client: MockWatchClient = MockWatchClient()) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
    }

    private func watch(_ id: String) -> ConnectedWatch {
        ConnectedWatch(
            id: WatchID(id),
            name: "Pebble \(id)",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(firmwareVersion: "v4.37.0", serialNumber: nil, hardwarePlatform: 18)
        )
    }

    private func face(_ name: String) -> WatchApplication {
        WatchApplication(
            id: UUID(),
            shortName: name,
            longName: name,
            companyName: "Somebody",
            versionLabel: "1.0",
            capabilities: [],
            targetPlatforms: [.emery],
            kind: .watchface
        )
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    // MARK: Diagnostics and language

    @Test func aDiagnosticsAnswerIsOnTheWatchItWasAskedOf() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)

        await model.takeScreenshot(watchID: WatchID("away"))
        await model.collectCoredump(watchID: WatchID("away"))

        #expect(model.diagnostics[WatchID("away")].feedback[.screenshot]?.isFailure == true)
        #expect(model.diagnostics[WatchID("away")].feedback[.coredump]?.isFailure == true)
        #expect(model.diagnostics[WatchID("other")].feedback.isEmpty)
        #expect(model.diagnostics.reportFeedback == nil)
    }

    /// One watch taking a pack neither holds another's buttons down nor puts
    /// its answer on another's screen.
    @Test func aLanguagePackOnOneWatchLeavesAnotherFree() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pack = directory.appending(path: "ja.pbl")
        try Data([1, 2, 3]).write(to: pack)
        model.language.installing.insert(WatchID("busy-elsewhere"))

        await model.installLanguagePack(from: pack, watchID: discovered.id)
        await model.installLanguagePack(from: pack, watchID: WatchID("away"))

        #expect(client.installedFiles.count == 1)
        #expect(model.language.feedback[discovered.id]?.isFailure == false)
        #expect(model.language.feedback[WatchID("away")]?.isFailure == true)
        #expect(model.language.feedback[WatchID("busy-elsewhere")] == nil)
        #expect(model.language.isInstalling(on: WatchID("busy-elsewhere")))
        #expect(!model.language.isInstalling(on: discovered.id))
    }

    // MARK: The active watchface

    @Test func eachWatchHasItsOwnActiveWatchface() async throws {
        let directory = temporaryDirectory()
        let previous = Defaults[.activeWatchfaceIDs]
        defer {
            try? FileManager.default.removeItem(at: directory)
            Defaults[.activeWatchfaceIDs] = previous
        }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        let first = face("First")
        let second = face("Second")
        model.applications.watchfaces = [first, second]
        let a = WatchConnection(client: client, watch: watch("a"))
        let b = WatchConnection(client: client, watch: watch("b"))

        model.handleEvent(.appRunStateChanged(.started(first.id)), from: a)
        model.handleEvent(.appRunStateChanged(.started(second.id)), from: b)

        #expect(model.applications.activeWatchfaceID(on: WatchID("a")) == first.id)
        #expect(model.applications.activeWatchfaceID(on: WatchID("b")) == second.id)
        #expect(model.applications.isActiveWatchface(first.id, on: nil))

        // One watch leaving its face says nothing about the other's.
        model.handleEvent(.appRunStateChanged(.stopped(second.id)), from: b)
        #expect(model.applications.activeWatchfaceID(on: WatchID("b")) == nil)
        #expect(model.applications.activeWatchfaceID(on: WatchID("a")) == first.id)
    }

    // MARK: Catalogue answers

    /// The answer to one application's install belongs to that application's
    /// screen, and outlives the install, which ends before it can be read.
    @Test func aCatalogAnswerIsShownOnlyForTheApplicationItIsAbout() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        let unsafe = CatalogApplication(
            id: UUID(),
            name: "Plain",
            developer: "Somebody",
            version: "1.0",
            downloadURL: URL(string: "http://store.invalid/plain.pbw")!,
            supportedPlatforms: [.emery]
        )

        let installed = await model.installCatalogApplication(unsafe)

        #expect(!installed)
        #expect(model.catalog.installingApplicationID == nil)
        #expect(model.catalog.feedback(about: unsafe.id)?.isFailure == true)
        #expect(model.catalog.feedback(about: UUID()) == nil)

        // Something about the catalogue as a whole is nobody's detail screen's.
        model.catalog.feedback = .failure("The store could not be searched.")
        #expect(model.catalog.feedback(about: unsafe.id) == nil)
        #expect(model.catalog.feedback?.isFailure == true)
    }

    // MARK: Removing and forgetting

    @Test func aRefusedRemovalSaysSoAndReportsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        let application = face("Kept")
        let library = try await model.applicationLibrary.upsert(application)
        model.updateApplications(library)
        model.applications.managementOperation = .reordering

        let removed = await model.removeApplication(id: application.id)

        #expect(!removed)
        #expect(model.applications.libraryFeedback?.isFailure == true)
        #expect(model.applications.all.contains { $0.id == application.id })

        model.applications.managementOperation = nil
        #expect(await model.removeApplication(id: application.id))
        #expect(!model.applications.all.contains { $0.id == application.id })
    }

    @Test func aWatchThatCouldNotBeForgottenIsStillThere() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let watchesURL = directory.appending(path: "watches.json")
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            watchStore: SavedWatchStore(fileURL: watchesURL),
            clientFactory: { _ in client }
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        // A directory where the file should be: the removal cannot be saved.
        try FileManager.default.removeItem(at: watchesURL)
        try FileManager.default.createDirectory(at: watchesURL, withIntermediateDirectories: true)

        let forgotten = await model.forgetWatch(id: discovered.id)

        #expect(!forgotten)
        #expect(model.watches.feedback?.isFailure == true)
    }

    // MARK: Connection state

    /// Read off what it is made of, so nothing has to remember to refresh it.
    @Test func theConnectionStateFollowsWhatItIsMadeOf() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        #expect(model.connectionState == .idle)

        model.lastConnectionError = .connectionTimedOut
        #expect(model.connectionState == .failed(.connectionTimedOut))

        model.connectingWatchIDs.insert(WatchID("b"))
        #expect(model.connectionState == .connecting(watchID: WatchID("b")))
        model.negotiatingWatchIDs.insert(WatchID("b"))
        #expect(model.connectionState == .negotiating(watchID: WatchID("b")))

        model.connectingWatchIDs.remove(WatchID("b"))
        model.connections.append(WatchConnection(client: client, watch: watch("a")))
        #expect(model.connectionState == .connected(watch("a")))
    }

    /// Add Watch shows what went wrong with the watch being added, and a scan
    /// that could not look at all — never another watch's failure.
    @Test func addWatchShowsItsOwnWatchsFailureAndTheScansButNoOtherWatchs() {
        let added = WatchID("added")
        let failures: [WatchID: WatchConnectionError] = [
            WatchID("reconnecting-elsewhere"): .connectionTimedOut,
        ]

        #expect(AddWatchSheet.connectionFeedback(
            watchBeingAdded: added,
            connectionFailures: failures,
            scanFailure: nil
        ) == nil)
        #expect(AddWatchSheet.connectionFeedback(
            watchBeingAdded: nil,
            connectionFailures: failures,
            scanFailure: nil
        ) == nil)
        #expect(AddWatchSheet.connectionFeedback(
            watchBeingAdded: added,
            connectionFailures: failures,
            scanFailure: .bluetoothUnavailable
        )?.isFailure == true)
        #expect(AddWatchSheet.connectionFeedback(
            watchBeingAdded: added,
            connectionFailures: [added: .protocolNegotiationFailed],
            scanFailure: .bluetoothUnavailable
        ) == .failure(WatchConnectionError.protocolNegotiationFailed.message))
    }
}

/// Only what the reader started answers on a screen. Work that runs by
/// itself — the health request every connect sends, a calendar or reminders
/// change noticed by EventKit — says what happened in the log instead.
@Suite
@MainActor
struct BackgroundFeedbackTests {
    private final class UnreadableRemindersApp: RemindersAppStore {
        struct Refusal: Error {}
        func reminders(allDayAt time: DateComponents) async throws -> [RemindersAppItem] { throw Refusal() }
        func add(_ reminder: TimelinePin) async throws -> String { throw Refusal() }
        func update(_ reminder: TimelinePin, identifier: String) async throws { throw Refusal() }
        func remove(identifier: String) async throws { throw Refusal() }
    }

    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
    }

    @Test func theHealthRequestAConnectSendsLeavesTheHealthScreenAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        #expect(model.health.feedback == nil)
        await model.reportHealth(.success("Health synchronization completed."), logging: "completed")
        #expect(model.health.feedback == nil)

        await model.requestHealthSync()
        #expect(model.health.feedback == .progress("Health synchronization requested."))
        await model.reportHealth(.success("Health synchronization completed."), logging: "completed")
        #expect(model.health.feedback == .success("Health synchronization completed."))
    }

    @Test func aRemindersChangeNoticedByItselfPutsNothingOnTheScreen() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())
        model.remindersAppStore = UnreadableRemindersApp()

        await model.reloadRemindersApp(reportsToReader: false)
        #expect(model.timeline.reminderFeedback == nil)

        await model.synchronizeRemindersApp()
        #expect(model.timeline.reminderFeedback?.isFailure == true)
    }

    /// The calendar read an EventKit notice starts is not the reader's either.
    @Test func aCalendarChangeNoticedByItselfPutsNothingOnTheScreen() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.reloadCalendar(reportsToReader: false)

        #expect(model.timeline.feedback == nil)
    }

    /// The watch is sent a reminder's Dismiss labelled in the phone's language
    /// rather than the English word the protocol layer used to hard-code.
    @Test func aReminderReachesTheWatchWithItsDismissLabelled() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        await model.addReminder(title: "歯医者", date: .now.addingTimeInterval(3_600))

        let sent = try #require(client.timelineReminders.first { $0.title == "歯医者" })
        #expect(sent.dismissTitle?.isEmpty == false)
        // The stored reminder carries no label: the language is the phone's at
        // the moment of writing.
        #expect(model.timeline.reminders.first { $0.title == "歯医者" }?.dismissTitle == nil)
    }
}

/// One window answers for what the model asks every window to show.
@Suite
@MainActor
struct FrontWindowTests {
    @Test func theWindowBroughtForwardLastIsFrontUntilItCloses() {
        let windows = FrontWindow()
        let first = UUID()
        let second = UUID()

        windows.bringForward(first)
        windows.bringForward(second)
        #expect(windows.isFront(second))
        #expect(!windows.isFront(first))

        windows.bringForward(first)
        #expect(windows.isFront(first))

        windows.close(first)
        #expect(windows.isFront(second))
    }
}
