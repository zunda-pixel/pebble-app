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
    func connectingToRecoveryFirmwareSkipsSynchronization() async throws {
        let client = MockPebbleClient()
        client.connectsAsRecoveryFirmware = true
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        #expect(model.connectedDevice?.isRunningRecoveryFirmware == true)
        // The recovery firmware rejects these endpoints and drops the link
        // when it is flooded with them.
        #expect(client.reorderedApplicationIDs.isEmpty)
        #expect(model.watchManagementErrorMessage != nil)
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

        #expect(model.connectedDevice?.id == "saved-bonded-watch")
        // Connected watches move out of the Nearby list.
        #expect(!model.discoveredDevices.contains { $0.id == "saved-bonded-watch" })
    }

    @Test
    func scanWhileConnectedPreservesConnection() async throws {
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

        await model.scan()

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(!model.discoveredDevices.contains { $0.id == discovered.id })
    }

    @Test
    func connectingToAnotherWatchKeepsBothConnected() async throws {
        let scanner = MockPebbleClient()
        var connectionClients: [String: MockPebbleClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            applicationLibrary: library,
            watchLibrary: watchLibrary,
            clientFactory: { deviceID in
                let client = MockPebbleClient()
                connectionClients[deviceID] = client
                return client
            }
        )

        await model.scan()
        let devices = model.discoveredDevices
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)

        #expect(model.connectedDevices.map(\.id) == [first.id, second.id])
        #expect(model.connections.count == 2)
        #expect(connectionClients.count == 2)

        // A test notification targeted at the second watch only reaches it.
        await model.sendTestNotification(deviceID: second.id)
        #expect(connectionClients[second.id]?.sentNotifications.count == 1)
        #expect(connectionClients[first.id]?.sentNotifications.isEmpty == true)

        await model.disconnect(deviceID: first.id)
        #expect(model.connectedDevices.map(\.id) == [second.id])
        #expect(connectionClients[first.id]?.disconnectedDevices.map(\.id) == [first.id])
    }

    @Test
    func connectingToTheConnectedWatchIsANoOp() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)
        await model.connect(to: discovered)

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(client.disconnectedDevices.isEmpty)
    }

    @Test
    func disconnectCancelsAnOngoingReconnect() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)
        client.emit(.reconnecting(deviceID: discovered.id))
        try await Task.sleep(for: .milliseconds(20))
        guard case .reconnecting = model.connectionState else {
            Issue.record("Expected the model to enter the reconnecting state")
            return
        }

        await model.disconnect()

        #expect(model.connectionState == .idle)
        #expect(client.disconnectedDevices.map(\.id) == [discovered.id])
    }

    @Test
    func forgettingAWatchStopsItsReconnectLoop() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)
        client.emit(.reconnecting(deviceID: discovered.id))
        try await Task.sleep(for: .milliseconds(20))

        await model.forgetWatch(id: discovered.id)

        #expect(client.disconnectedDevices.map(\.id) == [discovered.id])
        #expect(model.connections.isEmpty)
        #expect(!model.savedWatches.contains { $0.id == discovered.id })
    }

    @Test
    func resettingAWatchSendsTheCommandAndClosesTheConnection() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        await model.resetWatch(.factoryReset, deviceID: discovered.id)

        #expect(client.sentFrames.contains(ResetCodec.frame(.factoryReset)))
        // The watch reboots without answering, so the link is closed locally.
        #expect(model.connections.isEmpty)
        #expect(client.disconnectedDevices.map(\.id) == [discovered.id])
        #expect(model.installedApplicationIDs(on: discovered.id).isEmpty)
        #expect(model.watchResetStatusMessage != nil)
    }

    @Test
    func resettingWithoutAConnectionReportsAnError() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.resetWatch(.restart, deviceID: "missing-watch")

        #expect(client.sentFrames.isEmpty)
        #expect(model.watchManagementErrorMessage != nil)
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
