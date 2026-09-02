import Foundation
import PebbleProtocol
import PebbleTransport
import Testing
@testable import PebbleApp

/// The phone's Reminders app, as a test can have one.
///
/// It behaves the way EventKit does in the one way that matters here: a
/// reminder written to it is named by the Reminders app rather than by this
/// app, and is read back under that name.
@MainActor
final class FakeRemindersApp: RemindersAppStore {
    var items: [RemindersAppItem] = []
    var added: [PebbleTimelinePin] = []
    var updated: [PebbleTimelinePin] = []
    var removed: [String] = []
    private var written = 0

    func reminders() async throws -> [RemindersAppItem] { items }

    func add(_ reminder: PebbleTimelinePin) async throws -> String {
        written += 1
        let identifier = "reminders-app-\(written)"
        added.append(reminder)
        var copy = reminder
        copy.id = UUID()
        copy.parentApplicationID = RemindersBridge.applicationID
        copy.isFromWatch = false
        items.append(RemindersAppItem(identifier: identifier, reminder: copy))
        return identifier
    }

    func update(_ reminder: PebbleTimelinePin, identifier: String) async throws {
        guard let index = items.firstIndex(where: { $0.identifier == identifier }) else {
            throw RemindersBridgeError.gone
        }
        updated.append(reminder)
        items[index].reminder.title = reminder.title
        items[index].reminder.timestamp = reminder.timestamp
    }

    func remove(identifier: String) async throws {
        removed.append(identifier)
        items.removeAll { $0.identifier == identifier }
    }
}

@MainActor
@Suite
struct RemindersAppTests {
    private func item(
        _ title: String,
        identifier: String,
        inHours hours: Double = 1
    ) -> RemindersAppItem {
        RemindersAppItem(
            identifier: identifier,
            reminder: PebbleTimelinePin(
                parentApplicationID: RemindersBridge.applicationID,
                timestamp: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded()),
                title: title,
                subtitle: "リマインダー",
                body: nil,
                kind: .reminder
            )
        )
    }

    private func connectedModel(
        in directory: URL,
        client: MockPebbleClient,
        remindersApp: FakeRemindersApp
    ) async throws -> AppModel {
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchLibrary: PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json")),
            reminderLibrary: TimelinePinLibrary(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )
        model.remindersAppStore = remindersApp
        await model.scan()
        await model.connect(to: try #require(model.discoveredDevices.first))
        return model
    }

    @Test
    func aReminderInThePhonesAppIsSentToTheWatchAsAReminder() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shopping = item("牛乳を買う", identifier: "milk")
        remindersApp.items = [shopping]
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)

        await model.synchronizeRemindersApp()

        #expect(model.reminders.map(\.title) == ["牛乳を買う"])
        #expect(client.timelineReminders.map(\.id) == [shopping.reminder.id])
        #expect(client.timelineReminders.first?.kind == .reminder)
    }

    @Test
    func aReminderTheWatchMadeIsWrittenIntoThePhonesApp() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)
        let connection = try #require(model.activeConnections.first)
        var dictated = item("薬を飲む", identifier: "unused").reminder
        dictated.parentApplicationID = UUID()
        dictated.isFromWatch = true

        await model.keep(dictated, from: connection)

        #expect(remindersApp.added.map(\.title) == ["薬を飲む"])
    }

    @Test
    func aReminderTheWatchMadeIsWrittenThereOnceHoweverOftenTheAppIsRead() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)
        let connection = try #require(model.activeConnections.first)
        var dictated = item("犬の散歩", identifier: "unused").reminder
        dictated.parentApplicationID = UUID()
        dictated.isFromWatch = true
        await model.keep(dictated, from: connection)

        await model.synchronizeRemindersApp()
        await model.synchronizeRemindersApp()

        #expect(remindersApp.added.count == 1)
        // The copy read back is the same reminder, not a second one, and the
        // watch is not sent its own item back.
        #expect(model.reminders.map(\.id) == [dictated.id])
        #expect(client.timelineReminders.isEmpty)
    }

    @Test
    func aReminderDeletedInThePhonesAppIsTakenOffTheWatch() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dentist = item("歯医者", identifier: "dentist")
        remindersApp.items = [dentist]
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)
        await model.synchronizeRemindersApp()

        remindersApp.items = []
        await model.synchronizeRemindersApp()

        #expect(model.reminders.isEmpty)
        #expect(client.timelineReminders.isEmpty)
        #expect(client.deletedTimelineReminderIDs == [dentist.reminder.id])
    }

    @Test
    func aReminderTheWatchMadeAndTheReaderFinishedThereIsLetGoOfHere() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)
        let connection = try #require(model.activeConnections.first)
        var dictated = item("洗濯", identifier: "unused").reminder
        dictated.parentApplicationID = UUID()
        dictated.isFromWatch = true
        await model.keep(dictated, from: connection)
        await model.synchronizeRemindersApp()

        // Ticked off in the Reminders app: a completed reminder is not among
        // the ones it hands over, and that is the only word this app gets.
        remindersApp.items = []
        await model.synchronizeRemindersApp()

        #expect(model.reminders.isEmpty)
        #expect(client.deletedTimelineReminderIDs == [dictated.id])
    }

    @Test
    func lettingGoOfAReminderHereTakesItOutOfThePhonesApp() async throws {
        let client = MockPebbleClient()
        let remindersApp = FakeRemindersApp()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bins = item("ゴミ出し", identifier: "bins")
        remindersApp.items = [bins]
        let model = try await connectedModel(in: directory, client: client, remindersApp: remindersApp)
        await model.synchronizeRemindersApp()

        await model.removeReminders(model.reminders)

        #expect(remindersApp.removed == ["bins"])
        #expect(remindersApp.items.isEmpty)
    }

    /// A reminder whose day has gone is outside the window the Reminders app is
    /// read over, so its absence there is no news at all.
    @Test
    func aCopyWhoseTimeHasPassedIsNotTakenForFinished() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var yesterday = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: now.addingTimeInterval(-3600),
            title: "昨日の用事",
            subtitle: nil,
            body: nil,
            kind: .reminder,
            isFromWatch: true
        )
        yesterday.id = UUID()

        let outcome = RemindersAppSync.merged(
            kept: [yesterday],
            fromApp: [],
            mirrored: [yesterday.id: "gone-from-the-window"],
            now: now
        )

        #expect(outcome.finished.isEmpty)
        #expect(outcome.reminders.map(\.id) == [yesterday.id])
    }
}
