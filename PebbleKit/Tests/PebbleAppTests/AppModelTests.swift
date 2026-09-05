import PebbleProtocol
@testable import PebbleTransport
import Defaults
import Foundation
import Retry
import Testing
@testable import PebbleApp

@Suite
@MainActor
struct AppModelTests {
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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        #expect(!Defaults.Keys.hasCompletedWatchSetup.defaultValue)
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
    func connectingToRecoveryFirmwareSkipsSynchronization() async throws {
        let client = MockPebbleClient()
        client.connectsAsRecoveryFirmware = true
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        // A previously paired watch that no longer advertises: it is absent
        // from the mock's scan results and only reachable via retrieval.
        try await watchStore.record(PebbleDevice(
            id: "saved-bonded-watch",
            name: "My Pebble",
            model: .pebbleTime2,
            firmwareVersion: "v5.0.0",
            batteryLevel: 60
        ))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        try await watchStore.record(PebbleDevice(
            id: "saved-bonded-watch",
            name: "My Pebble",
            model: .pebbleTime2,
            firmwareVersion: "v5.0.0",
            batteryLevel: 60
        ))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)
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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)
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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            applicationLibrary: library,
            watchStore: watchStore,
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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        #expect(model.languagePackTransferProgress(on: discovered.id) == nil)
    }

    @Test
    func aForecastIsWrittenToTheWatchAndTakenBackWhenThePlaceGoes() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
    func aLauncherLineGoesOnlyToAWatchThatHasTheApp() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            appGlanceStore: AppGlanceStore(fileURL: directory.appending(path: "glances.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)
        let connection = try #require(model.connections.first)

        // The watch refuses a glance for an app it does not have, so asking is
        // pointless and the refusal would stop the rest of the pass.
        let absent = UUID()
        await model.setAppGlance(PebbleAppGlance(
            applicationID: absent,
            slices: [PebbleAppGlanceSlice(subtitleTemplate: "Kyoto 18°")]
        ))
        #expect(client.writtenAppGlances.isEmpty)

        model.installedApplicationIDsByWatch[connection.device.id] = [absent]
        await model.synchronizeAppGlances(on: connection)

        #expect(client.writtenAppGlances.map(\.applicationID) == [absent])

        // A line the reader emptied is one the watch is still showing.
        await model.setAppGlance(PebbleAppGlance(
            applicationID: absent,
            slices: [PebbleAppGlanceSlice(subtitleTemplate: "   ")]
        ))

        #expect(model.appGlances.isEmpty)
        #expect(client.writtenAppGlances.isEmpty)
    }

    @Test
    func oneWatchWaitingForAnAppDoesNotMakeAnotherWatchBusy() async throws {
        let scanner = MockPebbleClient()
        var connectionClients: [String: MockPebbleClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: scanner,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
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
        let firstConnection = try #require(model.connections.first { $0.device.id == first.id })
        let secondConnection = try #require(model.connections.first { $0.device.id == second.id })

        // The first watch launched an app and is being sent it.
        firstConnection.appFetchTask = Task { try? await Task.sleep(for: .seconds(60)) }
        defer { firstConnection.cancelApplicationFetch() }

        model.beginHandlingAppFetchRequest(
            AppFetchRequest(applicationID: UUID(), appBankID: 0),
            from: secondConnection
        )
        try await Task.sleep(for: .milliseconds(50))

        // The second watch is answered on its own account: there is no such app,
        // which is what it is told. "Busy" was the answer while the phone kept
        // one fetch slot for every watch at once.
        #expect(connectionClients[second.id]?.appFetchResponses == [.noData])
        #expect(connectionClients[first.id]?.appFetchResponses.isEmpty == true)
    }

    @Test
    func transferProgressStaysWithTheWatchItCameFrom() async throws {
        let scanner = MockPebbleClient()
        var connectionClients: [String: MockPebbleClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            applicationLibrary: library,
            watchStore: watchStore,
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
        let firstConnection = try #require(model.connections.first { $0.device.id == first.id })
        let secondConnection = try #require(model.connections.first { $0.device.id == second.id })
        let applicationID = UUID()
        firstConnection.beginTransfer(.firmware)
        secondConnection.beginTransfer(.application(applicationID))

        connectionClients[second.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 30, totalBytes: 100)
        ))
        try await Task.sleep(for: .milliseconds(20))

        // The application's bytes must not be read as the firmware's, on either
        // watch.
        #expect(model.applicationTransfer(on: second.id)?.progress == PutBytesTransferProgress(bytesSent: 30, totalBytes: 100))
        #expect(model.applicationTransfer(on: second.id)?.applicationID == applicationID)
        #expect(model.firmwareTransferProgress(on: second.id) == nil)
        #expect(model.firmwareTransferProgress(on: first.id) == PutBytesTransferProgress(bytesSent: 0, totalBytes: 0))
        #expect(model.applicationTransfer(on: first.id) == nil)

        connectionClients[first.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 4, totalBytes: 4096)
        ))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.firmwareTransferProgress(on: first.id) == PutBytesTransferProgress(bytesSent: 4, totalBytes: 4096))
        #expect(model.applicationTransfer(on: second.id)?.progress == PutBytesTransferProgress(bytesSent: 30, totalBytes: 100))

        // Nothing is reported once the work that owned the transfer is over.
        firstConnection.endTransfer()
        secondConnection.endTransfer()
        #expect(model.firmwareTransferProgress(on: first.id) == nil)
        #expect(model.applicationTransfer(on: second.id) == nil)
    }

    @Test
    func connectingToTheConnectedWatchIsANoOp() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

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
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        await model.resetWatch(.factoryReset, deviceID: discovered.id)

        #expect(client.sentFrames.contains(ResetCodec.frame(.factoryReset)))
        // The watch reboots without answering, so the link is closed locally.
        #expect(model.connections.isEmpty)
        #expect(client.disconnectedDevices.map(\.id) == [discovered.id])
        #expect(model.installedApplicationIDs(on: discovered.id).isEmpty)
        #expect(model.watchResetStatusMessages[discovered.id] != nil)
    }

    @Test
    func aWatchThatHasFinishedRestartingStopsSayingItIsRestarting() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)
        await model.resetWatch(.restart, deviceID: discovered.id)
        #expect(model.watchResetStatusMessages[discovered.id] != nil)

        // The watch says nothing on its way back: the link returning is the
        // whole of the news, and until it was read as news the screen said the
        // watch was restarting for as long as the app was running.
        await model.scan()
        await model.connect(to: try #require(model.discoveredDevices.first))

        #expect(model.watchResetStatusMessages[discovered.id] == nil)
    }

    @Test
    func resettingWithoutAConnectionReportsAnError() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)

        await model.resetWatch(.restart, deviceID: "missing-watch")

        #expect(client.sentFrames.isEmpty)
        #expect(model.watchManagementErrorMessage != nil)
    }

    @Test
    func aReminderWhoseTimeHasPassedIsKeptRatherThanSent() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        await model.connect(to: DiscoveredPebble(
            id: "mock-emery",
            name: "My Pebble",
            model: .pebbleTime2,
            signalStrength: -50
        ))

        await model.addReminder(title: "Past", date: .now.addingTimeInterval(-3600))

        // `MAX_REMINDER_AGE` is fifteen minutes: the watch refuses an older one
        // with a status the reader cannot act on, so it is never sent.
        #expect(client.timelineReminders.isEmpty)
        #expect(model.reminders.contains { $0.title == "Past" })

        await model.addReminder(title: "Later", date: .now.addingTimeInterval(3600))

        #expect(client.timelineReminders.map(\.title) == ["Later"])

        await model.removeReminders(model.reminders)
    }

    @Test
    func aReminderDeletedWhileTheWatchWasAwayIsTakenOffItWhenItReturns() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        let watch = DiscoveredPebble(
            id: "mock-emery",
            name: "My Pebble",
            model: .pebbleTime2,
            signalStrength: -50
        )
        await model.connect(to: watch)
        await model.addReminder(title: "Dentist", date: .now.addingTimeInterval(3600))
        #expect(client.timelineReminders.map(\.title) == ["Dentist"])

        await model.disconnect()
        await model.removeReminders(model.reminders)

        // The watch was not there to be told, and nothing else was going to
        // mention it again: it went on buzzing for a reminder that had been
        // thrown away.
        #expect(client.timelineReminders.map(\.title) == ["Dentist"])

        // A phone put down for the night: the app is gone from memory before
        // the watch is next in range, so what the watch was given has to be on
        // disk to be taken back.
        let afterRelaunch = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        await afterRelaunch.connect(to: watch)

        #expect(client.timelineReminders.isEmpty)
    }

    @Test
    func aConnectThatFailsIsRememberedAgainstThatWatch() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = DiscoveredPebble(id: "mock-emery", name: "My Pebble", model: .pebbleTime2, signalStrength: -50)
        client.connectionFailure = .protocolNegotiationFailed

        await model.connect(to: watch)

        // The watch's own screen has the Connect button; a failure that only
        // reached the log left that button looking like it had done nothing.
        #expect(model.connectionFailures[watch.id] == .protocolNegotiationFailed)
        #expect(model.connections.isEmpty)

        client.connectionFailure = nil
        await model.connect(to: watch)

        #expect(model.connectionFailures[watch.id] == nil)
    }

    @Test
    func aFailureIsKeptAgainstTheWatchWhileAScanIsStillRunning() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = DiscoveredPebble(id: "mock-emery", name: "My Pebble", model: .pebbleTime2, signalStrength: -50)
        client.connectionFailure = .pairingRemovedByWatch
        model.isScanning = true

        await model.connect(to: watch)

        // The Add Watch sheet scans the whole time it is open, and a scan in
        // progress is the state it reports; the failure has to be readable
        // beside it or the screen says nothing about a refused connect.
        #expect(model.connectionState == .scanning)
        #expect(model.connectionFailures[watch.id] == .pairingRemovedByWatch)
    }

    @Test
    func appModelRejectsAppMessageForUnknownApplication() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(client: client, applicationLibrary: library, watchStore: watchStore)
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
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
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
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        client.emit(.disconnected(.connectionTimedOut))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.connectionState == .failed(.connectionTimedOut))
        #expect(model.connectedDevice == nil)
        // The watch's own screen has the Connect button, so the reason belongs
        // against that watch and not only in the app-wide state.
        #expect(model.connectionFailures[discovered.id] == .connectionTimedOut)
    }

    @Test
    func aWatchThatKeepsFailingItsHandshakeSaysSoOnItsOwnScreen() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        // What the transport sends once it has stopped chasing a watch whose
        // links keep dying before a session.
        client.emit(.disconnected(.handshakeKeptFailing))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.connectionFailures[discovered.id] == .handshakeKeptFailing)
        #expect(model.connections.isEmpty)
        // Not "Reconnecting…" forever: the row goes quiet and the screen says
        // what to do about it.
        #expect(model.connectionState == .failed(.handshakeKeptFailing))
    }

    @Test
    func foregroundRecoveryKeepsConnectedSessionHealthy() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        await model.applicationDidBecomeActive()

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(client.reorderedApplicationIDs.last == [])
    }
}
