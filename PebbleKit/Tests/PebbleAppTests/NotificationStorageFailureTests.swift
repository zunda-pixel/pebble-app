import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// What the app says when it could not write down what the reader asked for.
///
/// It used to say the wrong thing. Three places discarded the write with `try?`
/// and then reported success anyway, so a setting the app had failed to keep
/// was announced as kept and came back changed at the next launch (#111).
@Suite
@MainActor
struct NotificationStorageFailureTests {
    private func makeModel(directory: URL) -> AppModel {
        AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    /// A directory where the store wants to put a file. Every write to that path
    /// then fails, whatever the store does, and it fails the same way on every
    /// machine — which a full disk would not.
    private func blockWrites(to name: String, in directory: URL) throws {
        let path = directory.appending(path: name)
        try? FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The change is kept, because it is already in force — and said to be
    /// unsaved, because it is.
    @Test func aQuietHoursChangeThatCouldNotBeSavedSaysSoAndStillApplies() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try blockWrites(to: "notification-preferences.json", in: directory)
        let model = makeModel(directory: directory)

        await model.setQuietHours(enabled: true, start: 22, end: 7)

        #expect(model.notifications.settingsFeedback?.isFailure == true)
        // In force for this run: the delivery path reads the model, not the file.
        #expect(model.notifications.preferences.quietHoursEnabled)
        #expect(model.notifications.preferences.quietHoursStart == 22)
    }

    @Test func mutingAnApplicationThatCouldNotBeSavedSaysSo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try blockWrites(to: "notification-preferences.json", in: directory)
        let model = makeModel(directory: directory)
        let applicationID = UUID()

        await model.setNotificationsEnabled(false, applicationID: applicationID)

        #expect(model.notifications.settingsFeedback?.isFailure == true)
        #expect(model.notifications.preferences.mutedApplicationIDs.contains(applicationID))
    }

    /// The same write, working, still answers for itself.
    @Test func aSettingThatWasSavedIsReportedAsSaved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)

        await model.setQuietHours(enabled: true, start: 22, end: 7)

        #expect(model.notifications.settingsFeedback?.isFailure == false)
    }

    /// Unlike a setting, an uncleared history may not look cleared: the claim is
    /// about the file, and the entries are still in it.
    @Test func aHistoryThatCouldNotBeClearedIsLeftOnScreen() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        model.notifications.sent = [
            SentNotification(appName: "Messages", title: "Lunch?", body: "At one.")
        ]
        try blockWrites(to: "sent-notifications.json", in: directory)

        await model.forgetSentNotifications()

        #expect(model.notifications.historyFeedback?.isFailure == true)
        #expect(model.notifications.sent.count == 1)
    }

    @Test func aHistoryThatWasClearedIsEmptiedAndSaysNothing() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        model.notifications.sent = [
            SentNotification(appName: "Messages", title: "Lunch?", body: "At one.")
        ]

        await model.forgetSentNotifications()

        #expect(model.notifications.sent.isEmpty)
        // Nothing to say: the empty screen is the answer.
        #expect(model.notifications.historyFeedback == nil)
    }
}
