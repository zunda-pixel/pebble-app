import Defaults
import Foundation
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// A notifier the tests can read back, standing in for the system centre —
/// which aborts in a bare test process and would prompt a person in any other.
@MainActor
final class SpyNotifier: LocalNotifying {
    var authorized = true
    var authorizationRequests = 0
    var posted: [(identifier: String, title: String, body: String)] = []
    var removed: [String] = []

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorized
    }

    func post(identifier: String, title: String, body: String) async {
        posted.append((identifier, title, body))
    }

    func remove(identifier: String) async {
        removed.append(identifier)
    }
}

/// The phone says so when a watch finishes charging — and only then (#99).
///
/// The rules are the official app's: only a climb to 100% counts, one
/// notification per charge, and the latch opens again at 97% or below.
///
/// Serialised because the switch lives in `Defaults`, which the whole test
/// process shares: two of these running at once would flip it under each
/// other.
@Suite(.serialized)
@MainActor
struct ChargeNotificationTests {
    private func makeModel(
        directory: URL,
        client: MockWatchClient,
        notifier: SpyNotifier
    ) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            localNotifier: notifier
        )
    }

    private func connect(
        _ model: AppModel,
        enabled: Bool = true
    ) async throws -> ConnectedWatch {
        // Instance state, not `Defaults`: the stored key is process-global, and
        // flipping it here once marched every concurrently running suite's
        // model into the real notification centre.
        model.notifyWhenFullyChargedEnabled = enabled
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        return try #require(model.connectedWatch)
    }

    private func report(_ model: AppModel, _ watch: ConnectedWatch, level: Int) async {
        var updated = watch
        updated.batteryLevel = level
        let connection = model.connections.first { $0.watch.id == watch.id }!
        model.handleEvent(.watchUpdated(updated), from: connection)
        // The handler hops through a task; let it land.
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func theClimbToFullIsSaidOnceWithTheWatchsName() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, client: client, notifier: notifier)
        let watch = try await connect(model)

        await report(model, watch, level: 99)
        await report(model, watch, level: 100)
        // The wobble around full.
        await report(model, watch, level: 99)
        await report(model, watch, level: 100)

        #expect(notifier.posted.count == 1)
        #expect(notifier.posted.first?.body.contains(watch.name) == true)
    }

    /// A watch that connects already full has finished charging some time ago,
    /// which is not news.
    @Test func aWatchThatArrivesFullSaysNothing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, client: client, notifier: notifier)
        let watch = try await connect(model)

        await report(model, watch, level: 100)
        await report(model, watch, level: 100)

        #expect(notifier.posted.isEmpty)
    }

    /// Down to 97 opens the latch; a new climb is a new charge.
    @Test func aFallToNinetySevenArmsTheNextCharge() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, client: client, notifier: notifier)
        let watch = try await connect(model)

        await report(model, watch, level: 99)
        await report(model, watch, level: 100)
        await report(model, watch, level: 97)
        await report(model, watch, level: 100)

        #expect(notifier.posted.count == 2)
    }

    @Test func nothingIsSaidWhileTheSwitchIsOff() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let notifier = SpyNotifier()
        let model = makeModel(directory: directory, client: client, notifier: notifier)
        let watch = try await connect(model, enabled: false)

        await report(model, watch, level: 99)
        await report(model, watch, level: 100)

        #expect(notifier.posted.isEmpty)
        #expect(notifier.authorizationRequests == 0)
    }

    /// Refused permission turns the switch back off and says so where the
    /// switch is, instead of promising what cannot arrive.
    @Test func aRefusedPermissionTurnsTheSwitchBackOff() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            Defaults[.notifyWhenFullyCharged] = false
        }
        let client = MockWatchClient()
        let notifier = SpyNotifier()
        notifier.authorized = false
        let model = makeModel(directory: directory, client: client, notifier: notifier)

        await model.setNotifyWhenFullyCharged(true)

        #expect(model.notifyWhenFullyChargedEnabled == false)
        #expect(Defaults[.notifyWhenFullyCharged] == false)
        #expect(model.phoneAlertsFeedback != nil)
        #expect(notifier.authorizationRequests == 1)

        notifier.authorized = true
        await model.setNotifyWhenFullyCharged(true)
        #expect(model.notifyWhenFullyChargedEnabled == true)
        #expect(model.phoneAlertsFeedback == nil)
    }
}
