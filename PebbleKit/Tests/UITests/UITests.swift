import API
import Foundation
import Testing
@testable import UI

@Suite
@MainActor
struct UITests {
    @Test
    func appModelScansConnectsAndSynchronizesEmptyLibrary() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(model.applicationManagementOperation == nil)
        #expect(client.reorderedApplicationIDs.last == [])
    }

    @Test
    func appModelRejectsAppMessageForUnknownApplication() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        client.emit(.appMessageReceived(AppMessageData(
            transactionID: 17,
            applicationID: UUID(),
            tuples: []
        )))
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))

        #expect(client.appMessageResponses.contains {
            $0.transactionID == 17 && !$0.acknowledged
        })
    }

    @Test
    func appModelReflectsReconnectAndRestoredDeviceEvents() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchLibrary: PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        client.emit(.reconnecting(deviceID: discovered.id))
        await Task.yield()
        #expect(model.connectionState == .reconnecting(deviceID: discovered.id))

        var restoredDevice = PebbleDevice(
            id: discovered.id,
            name: discovered.name,
            model: discovered.model,
            firmwareVersion: "v5.0.0-mock",
            batteryLevel: 84,
            serialNumber: "MOCK00000001"
        )
        restoredDevice.batteryLevel = 63
        client.emit(.deviceUpdated(restoredDevice))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.connectionState == .connected(restoredDevice))
        #expect(model.connectedDevice?.batteryLevel == 63)
    }

    @Test
    func appModelMarksUnexpectedDisconnectAsFailure() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchLibrary: PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        client.emit(.disconnected(.connectionTimedOut))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.connectionState == .failed(.connectionTimedOut))
        #expect(model.connectedDevice == nil)
    }
}
