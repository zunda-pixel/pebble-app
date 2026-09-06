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
        let client = MockWatchClient()
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
        let pin = TimelinePin(
            id: UUID(),
            parentApplicationID: applicationID,
            timestamp: Date(),
            title: "E2E",
            subtitle: nil,
            body: nil
        )

        let discovered = try #require(try await client.scan().first)
        let device = try await client.connect(to: discovered)
        try await client.write(.application(metadata))
        try await client.sendAppMessage(applicationID: applicationID, tuples: [])
        try await client.write(.timelinePin(pin))
        try await client.remove(.application(applicationID))
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
        let client = QEMUWatchClient()
        let discovered = try #require(try await client.scan().first)
        let device = try await client.connect(to: discovered)
        try await client.synchronizeTime()
        await client.disconnect(from: device)
    }
#endif

    @Test
    func appModelScansConnectsAndSynchronizesEmptyLibrary() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        #expect(model.connectedWatch?.id == discovered.id)
        #expect(model.applications.managementOperation == nil)
        #expect(client.reorderedApplicationIDs.last == [])
    }

    @Test
    func tokenNamesSeparateTheAccountFromEachWatch() {
        // A configuration page sees one token for the user and one per watch;
        // mixing them up would leak one watch's identity into another's page.
        #expect(PebbleTokenStore.accountTokenName == "pebbleAccountToken")
        #expect(PebbleTokenStore.watchTokenName(watchID: WatchID("abc")) == "pebbleWatchToken.abc")
        #expect(
            PebbleTokenStore.watchTokenName(watchID: WatchID("abc"))
                != PebbleTokenStore.watchTokenName(watchID: WatchID("def"))
        )
        #expect(PebbleTokenStore.watchTokenName(watchID: WatchID("abc")) != PebbleTokenStore.accountTokenName)
    }

    @Test
    func storedPreferencesUseOneTypedKeyEach() {
        // The keys were string literals repeated across the files that read
        // them, which is how the same preference came to be read two ways.
        #expect(Defaults.Keys.companionNotificationsEnabled.defaultValue)
        #expect(!Defaults.Keys.hasCompletedWatchSetup.defaultValue)
        #expect(Defaults.Keys.activeWatchfaceID.defaultValue == nil)
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
        #expect(isThrownStraightAway(WatchConnectionError.disconnected))
        #expect(isThrownStraightAway(WatchConnectionError.bluetoothUnavailable))
        #expect(!isThrownStraightAway(WatchConnectionError.connectionTimedOut))
        #expect(!isThrownStraightAway(PutBytesTransferError.invalidConfiguration))
    }

    @Test
    func connectingToRecoveryFirmwareSkipsSynchronization() async throws {
        let client = MockWatchClient()
        client.connectsAsRecoveryFirmware = true
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        #expect(model.connectedWatch?.isRunningRecoveryFirmware == true)
        // The recovery firmware rejects these endpoints and drops the link
        // when it is flooded with them.
        #expect(client.reorderedApplicationIDs.isEmpty)
        #expect(model.watches.feedback != nil)
    }

    @Test
    func scanReconnectsToSavedWatchThatDoesNotAdvertise() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        // A previously paired watch that no longer advertises: it is absent
        // from the mock's scan results and only reachable via retrieval.
        try await watchStore.record(ConnectedWatch(
            id: WatchID("saved-bonded-watch"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: 60,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        ))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()

        #expect(model.connectedWatch?.id == WatchID("saved-bonded-watch"))
        // Connected watches move out of the Nearby list.
        #expect(!model.discoveredWatches.contains { $0.id == WatchID("saved-bonded-watch") })
    }

    @Test
    func aWatchThatReconnectsOnItsOwnIsGivenALink() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        try await watchStore.record(ConnectedWatch(
            id: WatchID("saved-bonded-watch"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: 60,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        ))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )
        await model.loadSavedWatches()

        // The watch subscribed to the phone's protocol service by itself; no
        // scan ran and nothing else asked for this connection.
        await model.noteWatchThatReconnectedItself(watchID: WatchID("saved-bonded-watch"))

        #expect(model.connectedWatch?.id == WatchID("saved-bonded-watch"))
    }

    @Test
    func anUnknownBondedWatchIsOfferedRatherThanConnected() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )
        await model.loadSavedWatches()

        // Bonded but never added here: offered rather than connected, because
        // nothing else can surface it and the reader decides.
        await model.noteWatchThatReconnectedItself(watchID: WatchID("mock-emery"))

        #expect(model.connectedWatch == nil)
        #expect(model.watches.unknownBonded.map(\.id) == [WatchID("mock-emery")])

        let offered = try #require(model.watches.unknownBonded.first)
        await model.connect(to: offered)

        #expect(model.connectedWatch?.id == WatchID("mock-emery"))
        #expect(model.watches.saved.contains { $0.id == WatchID("mock-emery") })
        #expect(model.watches.unknownBonded.isEmpty)
    }

    @Test
    func scanWhileConnectedPreservesConnection() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        #expect(model.connectedWatch?.id == discovered.id)

        await model.scan()

        #expect(model.connectedWatch?.id == discovered.id)
        #expect(!model.discoveredWatches.contains { $0.id == discovered.id })
    }

    @Test
    func connectingToAnotherWatchKeepsBothConnected() async throws {
        let scanner = MockWatchClient()
        var connectionClients: [WatchID: MockWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore,
            clientFactory: { watchID in
                let client = MockWatchClient()
                connectionClients[watchID] = client
                return client
            }
        )

        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)

        #expect(model.connectedWatches.map(\.id) == [first.id, second.id])
        #expect(model.connections.count == 2)
        #expect(connectionClients.count == 2)

        // A test notification targeted at the second watch only reaches it.
        await model.sendTestNotification(watchID: second.id)
        #expect(connectionClients[second.id]?.sentNotifications.count == 1)
        #expect(connectionClients[first.id]?.sentNotifications.isEmpty == true)

        await model.disconnect(watchID: first.id)
        #expect(model.connectedWatches.map(\.id) == [second.id])
        #expect(connectionClients[first.id]?.disconnectedWatches.map(\.id) == [first.id])
    }

    @Test
    func aLanguagePackChosenFromAFileIsSentUnderTheNameTheWatchReads() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let packURL = directory.appending(path: "fr_FR.pbl")
        try Data([1, 2, 3, 4]).write(to: packURL)

        await model.installLanguagePack(from: packURL, watchID: discovered.id)

        let sent = try #require(client.installedFiles.first)
        #expect(sent.filename == "lang")
        #expect(sent.bytes == [1, 2, 3, 4])
        // The transfer is over, so nothing claims to still be running.
        #expect(model.languagePackTransferProgress(on: discovered.id) == nil)
    }

    @Test
    func aForecastIsWrittenToTheWatchAndTakenBackWhenThePlaceGoes() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        let report = WeatherReport(
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
        try await client.write(.weather(report))
        #expect(client.writtenWeather.map(\.id) == [report.id])

        // Writing the same place again replaces it rather than adding a second.
        try await client.write(.weather(report))
        #expect(client.writtenWeather.count == 1)

        try await client.remove(.weather(report.id))
        #expect(client.writtenWeather.isEmpty)
    }

    @Test
    func aNotificationSettingIsOnlyRememberedOnceTheWatchTakesIt() async throws {
        let client = MockWatchClient()
        let app = NotificationSourceApp(
            bundleID: "com.example.chat",
            displayName: "Chat",
            muteState: .always,
            stateUpdated: .now
        )

        try await client.write(.notificationSourceApp(app))
        #expect(client.writtenNotificationSourceApps.map(\.bundleID) == ["com.example.chat"])

        // The same app written again replaces its setting rather than adding
        // a second record.
        var muted = app
        muted.muteState = .never
        try await client.write(.notificationSourceApp(muted))
        #expect(client.writtenNotificationSourceApps.count == 1)
        #expect(client.writtenNotificationSourceApps.first?.muteState == .never)

        try await client.remove(.notificationSourceApp(bundleID: app.bundleID))
        #expect(client.writtenNotificationSourceApps.isEmpty)
    }

    @Test
    func aLauncherLineGoesOnlyToAWatchThatHasTheApp() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            appGlanceStore: AppGlanceStore(fileURL: directory.appending(path: "glances.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let connection = try #require(model.connections.first)

        // The watch refuses a glance for an app it does not have, so asking is
        // pointless and the refusal would stop the rest of the pass.
        let absent = UUID()
        await model.setAppGlance(AppGlance(
            applicationID: absent,
            slices: [AppGlanceSlice(subtitleTemplate: "Kyoto 18°")]
        ))
        #expect(client.writtenAppGlances.isEmpty)

        model.applications.installedIDsByWatch[connection.watch.id] = [absent]
        await model.synchronizeAppGlances(on: connection)

        #expect(client.writtenAppGlances.map(\.applicationID) == [absent])

        // A line the reader emptied is one the watch is still showing.
        await model.setAppGlance(AppGlance(
            applicationID: absent,
            slices: [AppGlanceSlice(subtitleTemplate: "   ")]
        ))

        #expect(model.appGlances.glances.isEmpty)
        #expect(client.writtenAppGlances.isEmpty)
    }

    @Test
    func oneWatchWaitingForAnAppDoesNotMakeAnotherWatchBusy() async throws {
        let scanner = MockWatchClient()
        var connectionClients: [WatchID: MockWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: scanner,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { watchID in
                let client = MockWatchClient()
                connectionClients[watchID] = client
                return client
            }
        )

        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)
        let firstConnection = try #require(model.connections.first { $0.watch.id == first.id })
        let secondConnection = try #require(model.connections.first { $0.watch.id == second.id })

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
        let scanner = MockWatchClient()
        var connectionClients: [WatchID: MockWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore,
            clientFactory: { watchID in
                let client = MockWatchClient()
                connectionClients[watchID] = client
                return client
            }
        )

        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)

        // Firmware going onto one watch while an application goes onto another.
        let firstConnection = try #require(model.connections.first { $0.watch.id == first.id })
        let secondConnection = try #require(model.connections.first { $0.watch.id == second.id })
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

    /// What one application's own screen sees while it is being sent.
    ///
    /// The other way round from `applicationTransfer(on:)`, which answers the
    /// library screen — that one has a watch picker and asks "what is this
    /// watch being sent". An application's page knows the application instead,
    /// and has to name the watches; there is more than one, because an
    /// installed application is pushed to every watch that is connected, and
    /// the two get on at their own speeds.
    ///
    /// The bytes used to be shown on the library screen alone. That screen is
    /// behind the application's, with its tab bar hidden, so installing from
    /// the detail screen left the reader an indeterminate spinner while the
    /// numbers went somewhere they could not look.
    @Test
    func oneApplicationsScreenSeesEveryWatchItIsGoingTo() async throws {
        let scanner = MockWatchClient()
        var connectionClients: [WatchID: MockWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: scanner,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore,
            clientFactory: { watchID in
                let client = MockWatchClient()
                connectionClients[watchID] = client
                return client
            }
        )

        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)

        let firstConnection = try #require(model.connections.first { $0.watch.id == first.id })
        let secondConnection = try #require(model.connections.first { $0.watch.id == second.id })

        // Nothing on its way yet.
        let applicationID = UUID()
        #expect(model.transfers(of: applicationID).isEmpty)

        // The same application to both watches, at different points.
        firstConnection.beginTransfer(.application(applicationID))
        secondConnection.beginTransfer(.application(applicationID))
        connectionClients[first.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 240, totalBytes: 512)
        ))
        connectionClients[second.id]?.emit(.transferProgress(
            PutBytesTransferProgress(bytesSent: 32, totalBytes: 512)
        ))
        try await Task.sleep(for: .milliseconds(20))

        let transfers = model.transfers(of: applicationID)
        #expect(transfers.count == 2)
        #expect(transfers.first { $0.watchID == first.id }?.progress
            == PutBytesTransferProgress(bytesSent: 240, totalBytes: 512))
        #expect(transfers.first { $0.watchID == second.id }?.progress
            == PutBytesTransferProgress(bytesSent: 32, totalBytes: 512))
        // Named, because the row says which watch rather than which application.
        #expect(transfers.first { $0.watchID == first.id }?.watchName == first.name)

        // Another application's page shows nothing while this one is being sent.
        #expect(model.transfers(of: UUID()).isEmpty)

        // Firmware is not this application's business, even on a watch that was
        // sending it a moment ago.
        firstConnection.endTransfer()
        firstConnection.beginTransfer(.firmware)
        #expect(model.transfers(of: applicationID).map(\.watchID) == [second.id])

        secondConnection.endTransfer()
        #expect(model.transfers(of: applicationID).isEmpty)
    }

    @Test
    func connectingToTheConnectedWatchIsANoOp() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        await model.connect(to: discovered)

        #expect(model.connectedWatch?.id == discovered.id)
        #expect(client.disconnectedWatches.isEmpty)
    }

    @Test
    func disconnectCancelsAnOngoingReconnect() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        client.emit(.reconnecting(watchID: discovered.id))
        try await Task.sleep(for: .milliseconds(20))
        guard case .reconnecting = model.connectionState else {
            Issue.record("Expected the model to enter the reconnecting state")
            return
        }

        await model.disconnect()

        #expect(model.connectionState == .idle)
        #expect(client.disconnectedWatches.map(\.id) == [discovered.id])
    }

    @Test
    func forgettingAWatchStopsItsReconnectLoop() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        client.emit(.reconnecting(watchID: discovered.id))
        try await Task.sleep(for: .milliseconds(20))

        await model.forgetWatch(id: discovered.id)

        #expect(client.disconnectedWatches.map(\.id) == [discovered.id])
        #expect(model.connections.isEmpty)
        #expect(!model.watches.saved.contains { $0.id == discovered.id })
    }

    @Test
    func resettingAWatchSendsTheCommandAndClosesTheConnection() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        await model.resetWatch(.factoryReset, watchID: discovered.id)

        #expect(client.sentFrames.contains(ResetCodec.frame(.factoryReset)))
        // The watch reboots without answering, so the link is closed locally.
        #expect(model.connections.isEmpty)
        #expect(client.disconnectedWatches.map(\.id) == [discovered.id])
        #expect(model.installedApplicationIDs(on: discovered.id).isEmpty)
        #expect(model.watches.resetFeedback[discovered.id] != nil)
    }

    @Test
    func aWatchThatHasFinishedRestartingStopsSayingItIsRestarting() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        await model.resetWatch(.restart, watchID: discovered.id)
        #expect(model.watches.resetFeedback[discovered.id] != nil)

        // The watch says nothing on its way back: the link returning is the
        // whole of the news, and until it was read as news the screen said the
        // watch was restarting for as long as the app was running.
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        #expect(model.watches.resetFeedback[discovered.id] == nil)
    }

    @Test
    func resettingWithoutAConnectionReportsAnError() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )

        await model.resetWatch(.restart, watchID: WatchID("missing-watch"))

        #expect(client.sentFrames.isEmpty)
        #expect(model.watches.feedback != nil)
    }

    @Test
    func aReminderWhoseTimeHasPassedIsKeptRatherThanSent() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        await model.connect(to: DiscoveredWatch(
            id: WatchID("mock-emery"),
            name: "My Pebble",
            model: .pebbleTime2,
            signalStrength: -50
        ))

        await model.addReminder(title: "Past", date: .now.addingTimeInterval(-3600))

        // `MAX_REMINDER_AGE` is fifteen minutes: the watch refuses an older one
        // with a status the reader cannot act on, so it is never sent.
        #expect(client.timelineReminders.isEmpty)
        #expect(model.timeline.reminders.contains { $0.title == "Past" })

        await model.addReminder(title: "Later", date: .now.addingTimeInterval(3600))

        #expect(client.timelineReminders.map(\.title) == ["Later"])

        await model.removeReminders(model.timeline.reminders)
    }

    @Test
    func aReminderDeletedWhileTheWatchWasAwayIsTakenOffItWhenItReturns() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        let watch = DiscoveredWatch(
            id: WatchID("mock-emery"),
            name: "My Pebble",
            model: .pebbleTime2,
            signalStrength: -50
        )
        await model.connect(to: watch)
        await model.addReminder(title: "Dentist", date: .now.addingTimeInterval(3600))
        #expect(client.timelineReminders.map(\.title) == ["Dentist"])

        await model.disconnect()
        await model.removeReminders(model.timeline.reminders)

        // The watch was not there to be told, and nothing else was going to
        // mention it again: it went on buzzing for a reminder that had been
        // thrown away.
        #expect(client.timelineReminders.map(\.title) == ["Dentist"])

        // A phone put down for the night: the app is gone from memory before
        // the watch is next in range, so what the watch was given has to be on
        // disk to be taken back.
        let afterRelaunch = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json"))
        )
        await afterRelaunch.connect(to: watch)

        #expect(client.timelineReminders.isEmpty)
    }

    @Test
    func aConnectThatFailsIsRememberedAgainstThatWatch() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = DiscoveredWatch(id: WatchID("mock-emery"), name: "My Pebble", model: .pebbleTime2, signalStrength: -50)
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = DiscoveredWatch(id: WatchID("mock-emery"), name: "My Pebble", model: .pebbleTime2, signalStrength: -50)
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        // Waited for rather than counted. This was one `await Task.yield()`
        // followed by the expectation, which asks the scheduler to consider
        // other work once and then asserts as though it had finished: the
        // event travels a stream consumed by another task, and on a machine
        // busy with the other four hundred tests the yield returned before it
        // arrived. The state was still `.connected` from the connect above —
        // not passed through, not yet reached — and the test went red for a
        // reason that had nothing to do with the app (#86, and the same trap
        // as #79).
        //
        // Nothing in the app advances past `.reconnecting` on its own —
        // `refreshConnectionState` keeps it while the connection's phase says
        // so — which is what makes waiting for it sound rather than a race
        // against a later transition. The loop is the assertion; with no
        // timeout of its own it is bounded by the suite's deadline, the same
        // choice `ChangeLog` makes in `ScriptedMusicTests`.
        client.emit(.reconnecting(watchID: discovered.id))
        while model.connectionState != .reconnecting(watchID: discovered.id) {
            await Task.yield()
        }

        var restoredDevice = ConnectedWatch(
            id: discovered.id,
            name: discovered.name,
            model: discovered.model,
            batteryLevel: 84,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0-mock",
                serialNumber: "MOCK00000001",
                hardwarePlatform: 18
            )
        )
        restoredDevice.batteryLevel = 63
        client.emit(.watchUpdated(restoredDevice))
        // Twenty milliseconds was the same guess with a wider margin: it says
        // nothing about whether the event has been handled, only that some
        // time has passed. `.watchUpdated` puts the connection back to
        // `.connected` and leaves it there, so this waits for it too.
        while model.connectionState != .connected(restoredDevice) {
            await Task.yield()
        }

        #expect(model.connectedWatch?.batteryLevel == 63)
    }

    @Test
    func appModelMarksUnexpectedDisconnectAsFailure() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        client.emit(.disconnected(.connectionTimedOut))
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.connectionState == .failed(.connectionTimedOut))
        #expect(model.connectedWatch == nil)
        // The watch's own screen has the Connect button, so the reason belongs
        // against that watch and not only in the app-wide state.
        #expect(model.connectionFailures[discovered.id] == .connectionTimedOut)
    }

    @Test
    func aWatchThatKeepsFailingItsHandshakeSaysSoOnItsOwnScreen() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        await model.applicationDidBecomeActive()

        #expect(model.connectedWatch?.id == discovered.id)
        #expect(client.reorderedApplicationIDs.last == [])
    }
}
