import API
import Defaults
import Foundation
import Retry
import Testing
import ZIPFoundation
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
    func tokenNamesSeparateTheAccountFromEachWatch() {
        // A configuration page sees one token for the user and one per watch;
        // mixing them up would leak one watch's identity into another's page.
        #expect(PebbleTokenStore.accountTokenName == "pebbleAccountToken")
        #expect(PebbleTokenStore.watchTokenName(watchID: "abc") == "pebbleWatchToken.abc")
        #expect(
            PebbleTokenStore.watchTokenName(watchID: "abc")
                != PebbleTokenStore.watchTokenName(watchID: "def")
        )
        #expect(PebbleTokenStore.watchTokenName(watchID: "abc") != PebbleTokenStore.accountTokenName)
    }

    @Test
    func storedPreferencesUseOneTypedKeyEach() {
        // The keys were string literals repeated across the files that read
        // them, which is how the same preference came to be read two ways.
        #expect(Defaults.Keys.companionNotificationsEnabled.defaultValue)
        #expect(!Defaults.Keys.hasCompletedOnboarding.defaultValue)
        #expect(Defaults.Keys.favoriteWatchfaceIDs.defaultValue.isEmpty)
        #expect(Defaults.Keys.activeWatchfaceID.defaultValue == nil)
        #expect(Defaults.Keys.catalogSource.defaultValue == nil)
        #expect(Defaults.Keys.healthKitLastExportDate.defaultValue == .distantPast)
    }

    @Test
    func workSentToAWatchIsRetriedOnlyWhenAnotherAttemptCouldWork() {
        let policy = RetryConfiguration<ContinuousClock>.watchWork
        func isThrownStraightAway(_ error: any Error) -> Bool {
            if case .throw = policy.recoverFromFailure(error) { return true }
            return false
        }

        #expect(policy.maxAttempts == 3)
        // Sleeping before reporting a link that is already gone only delays
        // the queue the work belongs in.
        #expect(isThrownStraightAway(PebbleConnectionError.disconnected))
        #expect(isThrownStraightAway(PebbleConnectionError.bluetoothUnavailable))
        #expect(!isThrownStraightAway(PebbleConnectionError.connectionTimedOut))
        #expect(!isThrownStraightAway(PutBytesTransferError.invalidConfiguration))
    }

    @Test
    func firmwareChosenWhileDisconnectedWaitsForTheWatch() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        // A watch running recovery firmware stays connected for only a few
        // seconds, so the file has to be accepted while it is away.
        try await watchLibrary.record(PebbleDevice(
            id: "recovery-watch",
            name: "My Pebble",
            model: .pebbleTime2,
            firmwareVersion: "v4.9.142",
            batteryLevel: nil,
            board: .obelixPVT
        ))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)
        await model.loadSavedWatches()
        let firmwareURL = try makeFirmwareArchive(in: directory)

        await model.installFirmware(from: firmwareURL, deviceID: "recovery-watch")

        let journal = try #require(model.firmwareUpdateJournal)
        #expect(journal.deviceID == "recovery-watch")
        #expect(client.installedFirmwarePackages.isEmpty)
    }

    private func makeFirmwareArchive(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "firmware.pbz")
        let archive = try Archive(url: url, accessMode: .create)
        let firmware = Data([4, 3, 2, 1])
        let manifest = Data("""
        {
          "manifestVersion": 1,
          "firmware": {
            "name": "firmware.bin",
            "type": "normal",
            "hwrev": "\(PebbleWatchBoard.obelixPVT.rawValue)",
            "size": \(firmware.count),
            "crc": \(PebbleCRC32.calculate([UInt8](firmware)))
          }
        }
        """.utf8)
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            provider: { position, size in
                manifest.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        try archive.addEntry(
            with: "firmware.bin",
            type: .file,
            uncompressedSize: Int64(firmware.count),
            provider: { position, size in
                firmware.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        return url
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
    func aWatchThatReconnectsOnItsOwnIsGivenALink() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        try await watchLibrary.record(PebbleDevice(
            id: "saved-bonded-watch",
            name: "My Pebble",
            model: .pebbleTime2,
            firmwareVersion: "v5.0.0",
            batteryLevel: 60
        ))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)
        await model.loadSavedWatches()

        // The watch subscribed to the phone's protocol service by itself; no
        // scan ran and nothing else asked for this connection.
        await model.noteWatchThatReconnectedItself(centralID: "saved-bonded-watch")

        #expect(model.connectedDevice?.id == "saved-bonded-watch")
    }

    @Test
    func anUnknownBondedWatchIsOfferedRatherThanConnected() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)
        await model.loadSavedWatches()

        // Bonded but never added here: offered rather than connected, because
        // nothing else can surface it and the reader decides.
        await model.noteWatchThatReconnectedItself(centralID: "mock-emery")

        #expect(model.connectedDevice == nil)
        #expect(model.unknownBondedWatches.map(\.id) == ["mock-emery"])

        let offered = try #require(model.unknownBondedWatches.first)
        await model.connect(to: offered)

        #expect(model.connectedDevice?.id == "mock-emery")
        #expect(model.savedWatches.contains { $0.id == "mock-emery" })
        #expect(model.unknownBondedWatches.isEmpty)
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
    func aLanguagePackChosenFromAFileIsSentUnderTheNameTheWatchReads() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packURL = directory.appending(path: "fr_FR.pbl")
        try Data([1, 2, 3, 4]).write(to: packURL)

        await model.installLanguagePack(from: packURL, deviceID: discovered.id)

        let sent = try #require(client.installedFiles.first)
        #expect(sent.filename == "lang")
        #expect(sent.bytes == [1, 2, 3, 4])
        // The transfer is over, so nothing claims to still be running.
        #expect(model.installationProgress == nil)
    }

    @Test
    func aForecastIsWrittenToTheWatchAndTakenBackWhenThePlaceGoes() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchLibrary = PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchLibrary: watchLibrary)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        let report = PebbleWeatherReport(
            id: UUID(),
            locationName: "Kyoto",
            isCurrentLocation: false,
            currentTemperature: 21,
            currentType: .sun,
            todayHigh: 26,
            todayLow: 18,
            tomorrowType: .lightRain,
            tomorrowHigh: 24,
            tomorrowLow: 17,
            shortPhrase: "Clear",
            updated: .now
        )
        try await client.writeWeather(report)
        #expect(client.writtenWeather.map(\.id) == [report.id])

        // Writing the same place again replaces it rather than adding a second.
        try await client.writeWeather(report)
        #expect(client.writtenWeather.count == 1)

        try await client.removeWeather(id: report.id)
        #expect(client.writtenWeather.isEmpty)
    }

    @Test
    func aNotificationSettingIsOnlyRememberedOnceTheWatchTakesIt() async throws {
        let client = MockPebbleClient()
        let app = NotificationSourceApp(
            bundleID: "com.example.chat",
            displayName: "Chat",
            muteState: .always,
            stateUpdated: .now
        )

        try await client.writeNotificationSourceApp(app)
        #expect(client.writtenNotificationSourceApps.map(\.bundleID) == ["com.example.chat"])

        // The same app written again replaces its setting rather than adding
        // a second record.
        var muted = app
        muted.muteState = .never
        try await client.writeNotificationSourceApp(muted)
        #expect(client.writtenNotificationSourceApps.count == 1)
        #expect(client.writtenNotificationSourceApps.first?.muteState == .never)

        try await client.removeNotificationSourceApp(bundleID: app.bundleID)
        #expect(client.writtenNotificationSourceApps.isEmpty)
    }

    @Test
    func transferProgressStaysWithTheWatchItCameFrom() async throws {
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

        // Firmware going onto one watch while an application goes onto another.
        model.firmwareTransferDeviceID = first.id
        model.applicationTransferDeviceID = second.id

        connectionClients[second.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 30, totalBytes: 100)
        ))
        try await Task.sleep(for: .milliseconds(20))

        // The application's bytes must not be read as the firmware's.
        #expect(model.installationProgress == PutBytesTransferProgress(bytesSent: 30, totalBytes: 100))
        #expect(model.firmwareUpdateProgress == nil)

        connectionClients[first.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 4, totalBytes: 4096)
        ))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.firmwareUpdateProgress == PutBytesTransferProgress(bytesSent: 4, totalBytes: 4096))
        #expect(model.installationProgress == PutBytesTransferProgress(bytesSent: 30, totalBytes: 100))

        // Nothing is reported once the work that owned the transfer is over.
        model.firmwareTransferDeviceID = nil
        model.applicationTransferDeviceID = nil
        #expect(model.firmwareUpdateProgress == nil)
        #expect(model.installationProgress == nil)
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
