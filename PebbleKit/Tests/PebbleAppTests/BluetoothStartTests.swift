import Foundation
import PebbleProtocol
import PebbleTransport
import Testing
@testable import PebbleApp

/// When the radio is opened.
///
/// Opening it is what raises the system's Bluetooth dialog, and the dialog is
/// the whole point of these: it should arrive when a watch is being asked for,
/// not while the app is starting for the first time.
@MainActor
@Suite
struct BluetoothStartTests {
    private func model(in directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )
    }

    @Test
    func anInstallWithNoWatchDoesNotOpenTheRadioWhileStarting() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(in: directory, client: client)

        await model.start()

        #expect(client.startBluetoothCount == 0)
        #expect(model.connections.isEmpty)
    }

    /// A watch that has been set up reconnects on its own and expects to find
    /// the phone's service already published.
    @Test
    func anInstallWithAWatchOpensTheRadioWhileStarting() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        _ = try await watchStore.record(ConnectedWatch(
            id: WatchID("saved-watch"),
            name: "Pebble Time 2",
            model: .pebbleTime2,
            firmwareVersion: "v5.0.0",
            batteryLevel: 80,
            serialNumber: "SERIAL"
        ))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: watchStore,
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )

        await model.start()

        // Counted rather than counted exactly: a saved watch connects
        // automatically, so the scan that follows asks for the radio again, and
        // asking twice is what the transport is built to shrug off.
        #expect(client.startBluetoothCount >= 1)
    }

    /// Whoever asks for a watch gets the radio opened for them, whether or not
    /// anything opened it at launch.
    @Test
    func askingForAWatchOpensTheRadio() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(in: directory, client: client)
        await model.start()

        await model.scan()

        #expect(client.startBluetoothCount == 1)
    }
}
