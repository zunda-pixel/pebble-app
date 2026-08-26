import API
import Foundation
import Testing
@testable import UI

@Suite
@MainActor
struct UITests {
    @Test
    func mockTransportCompletesCompanionLifecycle() async throws {
        let client = MockPebbleClient()
        let applicationID = UUID()
        let metadata = PebbleAppMetadata(
            applicationID: applicationID,
            flags: 0,
            iconResourceID: 0,
            appVersionMajor: 1,
            appVersionMinor: 0,
            sdkVersionMajor: 3,
            sdkVersionMinor: 0,
            name: "E2E"
        )
        let pin = PebbleTimelinePin(
            id: UUID(),
            parentApplicationID: applicationID,
            timestamp: Date(),
            title: "E2E",
            subtitle: nil,
            body: nil
        )

        let discovered = try #require(try await client.scan().first)
        let device = try await client.connect(to: discovered)
        try await client.registerApplication(metadata)
        try await client.sendAppMessage(applicationID: applicationID, tuples: [])
        try await client.upsertTimelinePin(pin)
        try await client.unregisterApplication(applicationID: applicationID)
        await client.disconnect(from: device)

        #expect(client.sentAppMessages.map(\.applicationID) == [applicationID])
        #expect(client.timelinePins.map(\.id) == [pin.id])
        #expect(client.unregisteredApplicationIDs == [applicationID])
        #expect(client.registeredApplications.isEmpty)
    }

#if os(macOS)
    @Test
    func qemuTransportSmokeTestWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PEBBLE_QEMU_E2E"] == "1" else { return }
        let client = QEMUPebbleClient()
        let discovered = try #require(try await client.scan().first)
        let device = try await client.connect(to: discovered)
        try await client.synchronizeTime()
        await client.disconnect(from: device)
    }
#endif

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
    func scanReconnectsToSavedWatchThatDoesNotAdvertise() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        // A previously paired watch that no longer advertises: it is absent
        // from the mock's scan results and only reachable via retrieval.
        try await watchLibrary.record(PebbleDevice(
            id: "saved-bonded-watch",
            name: "My Pebble",
            model: .pebbleTime2,
            firmwareVersion: "v5.0.0",
            batteryLevel: 60
        ))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()

        #expect(model.discoveredDevices.contains { $0.id == "saved-bonded-watch" })
        #expect(model.connectedDevice?.id == "saved-bonded-watch")
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

    @Test
    func foregroundRecoveryKeepsConnectedSessionHealthy() async throws {
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

        await model.applicationDidBecomeActive()

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(client.reorderedApplicationIDs.last == [])
    }
}
