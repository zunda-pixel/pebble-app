public import PebbleProtocol
import Defaults
public import Foundation
import Observation
import SwiftUI

public enum ApplicationManagementOperation: Equatable, Sendable {
    case importing
    case installing(UUID)
    case removing(UUID)
    case reordering
    case synchronizing
}

/// An application on its way to one watch.
public struct ApplicationTransfer: Equatable, Sendable {
    public var applicationID: UUID
    public var name: String?
    public var progress: PutBytesTransferProgress
}

/// One application on its way to one named watch.
///
/// The other way round from `ApplicationTransfer`, which names the application
/// for a screen that already knows the watch. An application's own screen knows
/// the application and has to name the watch — and there can be more than one,
/// because the same application goes to every watch that is connected.
public struct WatchApplicationTransfer: Equatable, Sendable, Identifiable {
    public var watchID: WatchID
    public var watchName: String
    public var progress: PutBytesTransferProgress

    public var id: WatchID { watchID }
}

public enum CatalogInstallationState: Equatable, Sendable {
    case available
    case installed
    case updateAvailable
    case incompatible
}

@MainActor
@Observable
public final class AppModel {
    public internal(set) var connectionState: WatchConnectionState = .idle
    public internal(set) var connections: [WatchConnection] = []
    /// The answer to flipping one of the phone-alert switches on the Settings
    /// screen — refused notification permission, mostly. Beside the switches,
    /// because that is where the reader is looking when it happens.
    public internal(set) var phoneAlertsFeedback: FeatureFeedback?
    public internal(set) var connectingWatchIDs: Set<WatchID> = []
    /// Why the last attempt at each watch ended. A watch has its own screen with
    /// its own Connect button, and a failure that only reached the log left that
    /// button looking like it had done nothing.
    public internal(set) var connectionFailures: [WatchID: WatchConnectionError] = [:]
    public internal(set) var isScanning = false
    public internal(set) var discoveredWatches: [DiscoveredWatch] = []
    /// Which of the watches being connected have got past the link coming up.
    ///
    /// Not observable in its own right: it is only ever read by
    /// `refreshConnectionState`, and `connectionState` is what a screen shows.
    @ObservationIgnored var negotiatingWatchIDs: Set<WatchID> = []

    // Everything else a screen reads lives on the feature it belongs to.
    //
    // There were eighty-six stored properties here, mutated from eighteen
    // extensions, and the only way to find out which feature owned one was to
    // read its name and hope. Each group is `@Observable` in its own right, so
    // a view reading `model.weather.reports` is invalidated by a forecast and
    // not by a screenshot.
    public let watches = WatchesModel()
    public let applications = ApplicationsModel()
    public let appGlances = AppGlancesModel()
    public let catalog = CatalogModel()
    public let firmware = FirmwareModel()
    public let language = LanguageModel()
    public let timeline = TimelineModel()
    public let notifications = NotificationsModel()
    public let watchSettings = WatchSettingsModel()
    public let diagnostics = DiagnosticsModel()
    public let health = HealthModel()
    public let weather = WeatherModel()

    public var isScanningOrConnecting: Bool {
        switch connectionState {
        case .scanning, .connecting:
            true
        default:
            false
        }
    }

    public var connectedWatches: [ConnectedWatch] {
        activeConnections.map(\.watch)
    }

    public var connectedWatch: ConnectedWatch? {
        activeConnections.first?.watch
    }

    var activeConnections: [WatchConnection] {
        connections.filter(\.isConnected)
    }

    /// What one watch is being sent, for the screen showing that watch.
    ///
    /// Named rather than found: `connection(for:)` falls back to the first watch
    /// when given nothing, and "whichever watch is first" is not an answer to
    /// "what is this one doing".
    public func applicationTransfer(on watchID: WatchID) -> ApplicationTransfer? {
        guard let connection = connections.first(where: { $0.watch.id == watchID }),
              let applicationID = connection.applicationBeingSent,
              let progress = connection.transferProgress else {
            return nil
        }
        return ApplicationTransfer(
            applicationID: applicationID,
            name: (applications.apps + applications.watchfaces).first { $0.id == applicationID }?.displayName,
            progress: progress
        )
    }

    /// Which watches this one application is on its way to, and how far it has
    /// got on each.
    ///
    /// For the application's own screen, which knows the application and not
    /// the watch. It asks about this application rather than about whatever is
    /// being sent, the way `ApplicationOperationBanner` has to on the library
    /// screen: an application's page has no business showing another's bar.
    ///
    /// One entry per watch, because an installed application is pushed to every
    /// connected watch and the two transfers get on at their own speeds.
    ///
    /// Says nothing about the download that comes first. Installing from the
    /// store fetches the package over the network before any watch is written
    /// to, and during that there is no transfer to report — `catalog.feedback`
    /// is what says "Downloading Orbit…".
    public func transfers(of applicationID: UUID) -> [WatchApplicationTransfer] {
        connections.compactMap { connection in
            guard connection.applicationBeingSent == applicationID,
                  let progress = connection.transferProgress else { return nil }
            return WatchApplicationTransfer(
                watchID: connection.watch.id,
                watchName: connection.watch.name,
                progress: progress
            )
        }
    }

    public func firmwareTransferProgress(on watchID: WatchID) -> PutBytesTransferProgress? {
        connections.first { $0.watch.id == watchID }?.transferProgress(for: .firmware)
    }

    public func languagePackTransferProgress(on watchID: WatchID) -> PutBytesTransferProgress? {
        connections.first { $0.watch.id == watchID }?.transferProgress(for: .languagePack)
    }

    /// Whether any watch is being sent an application it asked for. The library
    /// operations wait on this, because they would rewrite the package under a
    /// transfer already reading it.
    public var isHandlingAppFetch: Bool {
        connections.contains { $0.isFetchingApplication }
    }

    func connection(for watchID: WatchID?) -> WatchConnection? {
        guard let watchID else {
            return activeConnections.first
        }
        return connections.first { $0.watch.id == watchID }
    }

    let scannerClient: any WatchClient
    let clientFactory: @MainActor (WatchID) -> any WatchClient
    let applicationLibrary: WatchApplicationLibrary
    let watchStore: SavedWatchStore
    let timelineStore: TimelinePinStore
    let reminderStore: TimelinePinStore
    /// The reminders derived from calendar event alerts, kept apart from the
    /// reader's own: these are replaced wholesale by every calendar read, and
    /// deleting one by hand would only have the next read put it back.
    let calendarReminderStore: TimelinePinStore
    let healthStore: WatchHealthStore
    let appCatalog: AppCatalog
    let languagePackCatalog = PebbleLanguagePackCatalog()
    let weatherBridge = WeatherBridge()
    // Held as a function so a test can answer for some places and refuse for
    // others, which WeatherKit itself cannot be asked to produce.
    @ObservationIgnored
    var fetchWeatherReport: (WeatherPlace, Bool) async throws -> WeatherReport = {
        place, usesFahrenheit in
        try await WeatherBridge().report(for: place, inFahrenheit: usesFahrenheit)
    }
    let phoneLocationSource = PhoneLocationSource()
    let pendingNotificationStore: PendingNotificationStore
    let sentNotificationStore: SentNotificationStore
    let notificationPreferenceStore: NotificationPreferenceStore
    let pendingTimelineOperationStore: PendingTimelineOperationStore
    let pendingAppMessageStore: PendingAppMessageStore
    let pendingFirmwareUpdateStore: PendingFirmwareUpdateStore
    let localNotifier: any LocalNotifying

    /// The two phone-alert switches, held on the instance rather than read out
    /// of `Defaults` at the moment of use. `Defaults` is process-global, and in
    /// the test process one suite flipping a key there marched every other
    /// suite's model into the real notification centre — which aborts without
    /// an app bundle — and the real firmware catalogue. The setters keep
    /// `Defaults` as the stored copy; this is the working one.
    var notifyWhenFullyChargedEnabled = Defaults[.notifyWhenFullyCharged]
    var notifyAboutFirmwareUpdatesEnabled = Defaults[.notifyAboutFirmwareUpdates]

    /// The last battery level each watch reported this session, for telling a
    /// climb to 100% from a watch that connected already full. Cleared when the
    /// watch goes, so a reconnect starts over rather than notifying off a
    /// reading from another wearing.
    var chargeLevels: [WatchID: Int] = [:]
    /// The watches already told about this charge. Unlatched when the level
    /// falls to 97% or below, the way the official app does it, so the wobble
    /// around full does not ring twice.
    var chargeNotified: Set<WatchID> = []
    let firmwareCatalog: PebbleOSFirmwareCatalog

    /// When each (watch, running version) pair last got a *successful* answer
    /// from the firmware catalogue, for the fifteen-minute cache the official
    /// app keeps. Failures are deliberately absent: a network that refused is
    /// not a catalogue that answered "up to date".
    var firmwareCheckedAt: [String: Date] = [:]
    var pendingAppMessages: [StoredAppMessage] = []
    let calendarBridge = CalendarBridge()
    // Held behind its protocol so a test can answer for the Reminders app,
    // which nothing can write to without a person saying yes to it first.
    @ObservationIgnored var remindersAppStore: any RemindersAppStore = RemindersBridge()
    @ObservationIgnored var calendarChangesTask: Task<Void, Never>?
    #if os(iOS)
    let healthKitBridge = HealthKitBridge()
    #endif
    let notificationSourceAppStore: NotificationSourceAppStore
    let appGlanceStore: AppGlanceStore
    let speechBridge = SpeechBridge()
    var voiceTranscriptionReadiness = VoiceTranscriptionReadiness.turnedOff
    @ObservationIgnored lazy var musicCoordinator = MusicCoordinator(
        source: makeSystemMusicSource(),
        send: { [weak self] frame in try await self?.broadcast(frame) }
    )
    @ObservationIgnored lazy var phoneCallCoordinator = PhoneCallCoordinator(
        source: makeSystemCallSource(),
        send: { [weak self] frame in try await self?.broadcast(frame) }
    )
    @ObservationIgnored var lastConnectionError: WatchConnectionError?
    @ObservationIgnored var firmwareUpdateTask: Task<Void, any Error>?
    @ObservationIgnored var hasLoadedApplications = false
    @ObservationIgnored var pendingImportSnapshots: [UUID: WatchApplicationLibrarySnapshot] = [:]
    @ObservationIgnored var needsApplicationSynchronization = false
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var recentNotificationFingerprints: [String: Date] = [:]
    @ObservationIgnored var pendingNotifications: [PendingDelivery<PebbleTimelineNotification>] = []
    // Both the app coming forward and a watch finishing its synchronization ask
    // for a flush; two at once hand the watch everything twice.
    @ObservationIgnored var pendingNotificationFlush: Task<Void, Never>?
    @ObservationIgnored var pendingAppMessageFlush: Task<Void, Never>?
    @ObservationIgnored lazy var companionRuntime = PebbleCompanionRuntime(
        openURLHandler: { [weak self] url in self?.openConfigurationURL(url) },
        appMessageHandler: { [weak self] applicationID, tuples in
            guard let self else { throw WatchConnectionError.disconnected }
            try await self.sendOrQueueAppMessage(applicationID: applicationID, tuples: tuples)
        },
        notificationHandler: { [weak self] application, title, body in
            guard let self else { throw WatchConnectionError.disconnected }
            try await self.sendCompanionNotification(
                application: application,
                title: title,
                body: body
            )
        },
        activeWatchHandler: { [weak self] in self?.connectedWatch },
        // The same position the weather is fetched for. A script asking for one
        // is asking the phone, because WebKit gives an app no way to grant the
        // web's own `navigator.geolocation`.
        locationHandler: { [weak self] in
            guard let self else { throw WeatherSourceError.locationNotAllowed }
            return try await self.phoneLocationSource.currentLocation()
        }
    )

    /// One directory for the fourteen stores.
    ///
    /// Four of them were injectable and the other ten took their own default,
    /// which was the reader's real Application Support directory. In the app
    /// that is right and invisible — there is one model. In the test suite,
    /// which Swift Testing runs concurrently, it meant every model shared the
    /// same queues: one test's pending notification was flushed to another
    /// test's watch, and a full run rewrote a real notification history (#59).
    /// Each store still owns its own filename; only where they all sit is
    /// anyone else's business.
    public init(
        client: any WatchClient,
        storageDirectory: StorageDirectory = .applicationSupport,
        applicationLibrary: WatchApplicationLibrary? = nil,
        watchStore: SavedWatchStore? = nil,
        appGlanceStore: AppGlanceStore? = nil,
        reminderStore: TimelinePinStore? = nil,
        appCatalog: AppCatalog? = nil,
        clientFactory: (@MainActor (WatchID) -> any WatchClient)? = nil,
        localNotifier: (any LocalNotifying)? = nil,
        firmwareCatalog: PebbleOSFirmwareCatalog? = nil
    ) {
        // The real one only touches the system centre inside its methods, so a
        // test that never turns a notifying feature on never reaches it.
        self.localNotifier = localNotifier ?? SystemLocalNotifier()
        self.firmwareCatalog = firmwareCatalog ?? PebbleOSFirmwareCatalog()
        scannerClient = client
        // Without a factory every connection shares the scanning client, which
        // limits the app to one watch at a time (mock and QEMU transports).
        self.clientFactory = clientFactory ?? { _ in client }
        // These four are still passed in where a test has to hold the same
        // instance the model holds — seeding a library and then reading what
        // the model did with it. Two actors over one file would each have
        // their own cache of it.
        self.applicationLibrary = applicationLibrary ?? WatchApplicationLibrary(directory: storageDirectory)
        self.watchStore = watchStore ?? SavedWatchStore(directory: storageDirectory)
        self.appGlanceStore = appGlanceStore ?? AppGlanceStore(directory: storageDirectory)
        self.reminderStore = reminderStore
            ?? TimelinePinStore(directory: storageDirectory, name: "timeline.reminders")
        timelineStore = TimelinePinStore(directory: storageDirectory, name: "timeline")
        calendarReminderStore = TimelinePinStore(directory: storageDirectory, name: "timeline.calendar-reminders")
        healthStore = WatchHealthStore(directory: storageDirectory)
        // Passed in for the same reason as the stores above: a test that has to
        // answer for the store needs to hold the catalogue the model holds.
        self.appCatalog = appCatalog ?? AppCatalog(directory: storageDirectory)
        pendingNotificationStore = PendingNotificationStore(directory: storageDirectory)
        sentNotificationStore = SentNotificationStore(directory: storageDirectory)
        notificationPreferenceStore = NotificationPreferenceStore(directory: storageDirectory)
        pendingTimelineOperationStore = PendingTimelineOperationStore(directory: storageDirectory)
        pendingAppMessageStore = PendingAppMessageStore(directory: storageDirectory)
        pendingFirmwareUpdateStore = PendingFirmwareUpdateStore(directory: storageDirectory)
        notificationSourceAppStore = NotificationSourceAppStore(directory: storageDirectory)
        notifications.companionEnabled = Defaults[.companionNotificationsEnabled]
        applications.activeWatchfaceID = Defaults[.activeWatchfaceID]
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await loadSavedWatches()
        await restorePendingNotifications()
        notifications.preferences = (try? await notificationPreferenceStore.preferences()) ?? NotificationDeliveryPreferences()
        pendingAppMessages = (try? await pendingAppMessageStore.messages()) ?? []
        await loadTimeline()
        await loadHealth()
        await loadCatalog()
        firmware.journal = try? await pendingFirmwareUpdateStore.journal()
        loadDownloadedFirmware()
        loadWeatherPlaces()
        loadWatchSettings()
        notifications.sourceApps = (try? await notificationSourceAppStore.apps()) ?? []
        notifications.sent = (try? await sentNotificationStore.notifications()) ?? []
        await loadAppGlances()
        musicCoordinator.start()
        phoneCallCoordinator.start()
        observeWatchesReconnectingThemselves()
        // A watch that has been set up reconnects on its own, so the radio has
        // to be open before it does — but only where there is a watch to expect.
        // Opening it is what raises the system's Bluetooth dialog, and an
        // install with no watch yet would be asked for permission before it had
        // asked for anything.
        if !watches.saved.isEmpty {
            scannerClient.startBluetooth()
        }
        if watches.saved.contains(where: \.automaticallyConnects) {
            await scan()
        }
        observeEventKitChanges()
        // The weather's clock, for as long as the app is running. Five minutes
        // is how often staleness is *noticed*, not how often anything is
        // fetched — the interval setting decides that. The OS decides whether
        // the app runs at all, which is why nothing here promises a time.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                guard let self else { return }
                await self.refreshWeatherIfStale()
            }
        }
    }

    public func applicationDidBecomeActive() async {
        await start()
        await PebbleDiagnostics.shared.record(category: "lifecycle", message: "Application became active")
        // Coming to the foreground is one of the few moments iOS promises the
        // app is running, which makes it the reliable one of the staleness
        // triggers.
        await refreshWeatherIfStale()
        if !activeConnections.isEmpty {
            for connection in activeConnections {
                try? await connection.client.synchronizeTime()
            }
            await restorePendingNotifications()
            pendingAppMessages = (try? await pendingAppMessageStore.messages()) ?? pendingAppMessages
            await flushPendingNotifications()
            await flushPendingAppMessages()
            await synchronizeTimeline()
        } else if !isScanning, connectingWatchIDs.isEmpty, connections.isEmpty {
            if watches.saved.contains(where: \.automaticallyConnects) {
                await scan()
            }
        }
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        if connections.isEmpty, connectingWatchIDs.isEmpty {
            connectionState = .scanning
        }
        defer {
            isScanning = false
            refreshConnectionState()
        }

        do {
            await loadSavedWatches()
            // Asking for a watch is the moment the radio is worth its dialog.
            scannerClient.startBluetooth()
            var devices = try await scannerClient.scan()
            let connectedIDs = Set(connections.map(\.watch.id))
            let missingSavedWatches = watches.saved
                .filter { saved in
                    !connectedIDs.contains(saved.id) && !devices.contains { $0.id == saved.id }
                }
                .map { saved in
                    DiscoveredWatch(id: saved.id, name: saved.name, model: saved.model, signalStrength: 0)
                }
            if !missingSavedWatches.isEmpty,
               let retrieved = try? await scannerClient.retrieveKnownWatches(missingSavedWatches) {
                devices.append(contentsOf: retrieved)
            }
            discoveredWatches = devices.filter { !connectedIDs.contains($0.id) }
            refreshConnectionState()
            let automaticTargets = discoveredWatches.filter { discovered in
                watches.saved.contains { $0.id == discovered.id && $0.automaticallyConnects }
            }
            for device in automaticTargets {
                await connect(to: device)
            }
        } catch let error as WatchConnectionError {
            if connections.isEmpty {
                lastConnectionError = error
            }
        } catch {
            if connections.isEmpty {
                lastConnectionError = .bluetoothUnavailable
            }
        }
    }

    public func connect(to watch: SavedWatch) async {
        await connect(to: DiscoveredWatch(
            id: watch.id,
            name: watch.name,
            model: watch.model,
            signalStrength: 0
        ))
    }

    public func connect(to device: DiscoveredWatch) async {
        guard !connectingWatchIDs.contains(device.id),
              !connections.contains(where: { $0.watch.id == device.id }) else {
            return
        }
        connectingWatchIDs.insert(device.id)
        connectionFailures[device.id] = nil
        refreshConnectionState()
        Task { [id = device.id] in
            await PebbleDiagnostics.shared.record(
                category: "connection",
                message: "connect requested for \(id)"
            )
        }
        defer {
            connectingWatchIDs.remove(device.id)
            negotiatingWatchIDs.remove(device.id)
            refreshConnectionState()
        }

        let connectionClient = clientFactory(device.id)
        do {
            let connectedWatch = try await connectionClient.connect(to: device) { [weak self] _ in
                // Both phases mean the same thing to a screen: the link is up
                // and the watch has not finished answering. They are reported
                // separately because a watch that reaches the first and never
                // the second is one whose protocol service is unusable, and
                // the log needs to tell those apart.
                guard let self else { return }
                self.negotiatingWatchIDs.insert(device.id)
                self.refreshConnectionState()
            }
            lastConnectionError = nil
            connectionFailures[device.id] = nil
            let connection = WatchConnection(
                client: connectionClient,
                watch: connectedWatch,
                voiceProvider: speechBridge
            )
            connections.append(connection)
            connection.startObserving(
                onEvent: { [weak self] connection, event in
                    self?.handleEvent(event, from: connection)
                },
                onFrame: { [weak self] connection, frame in
                    await self?.handleCompanionFrame(frame, from: connection)
                }
            )
            discoveredWatches.removeAll { $0.id == device.id }
            watches.unknownBonded.removeAll { $0.id == device.id }
            // Leaving the id here until this function returns would rank the whole
            // post-connect synchronization as "connecting".
            connectingWatchIDs.remove(device.id)
            refreshConnectionState()
            await recordConnectedWatch(connectedWatch)
            await restorePendingNotifications()
            await PebbleDiagnostics.shared.record(category: "connection", message: "Watch connected")
            await synchronizeEverything(on: connection)
        } catch let error as WatchConnectionError {
            lastConnectionError = error
            connectionFailures[device.id] = error
            if !connections.isEmpty {
                watches.feedback = .failure(error.message)
            }
            await PebbleDiagnostics.shared.record(.error, category: "connection", message: error.logDescription)
        } catch {
            lastConnectionError = .protocolNegotiationFailed
            connectionFailures[device.id] = .protocolNegotiationFailed
        }
    }

    func refreshConnectionState() {
        // `.negotiating` before `.connecting`: they are one connect at two
        // stages, and the second is the one that takes the seconds.
        if let negotiatingID = connectingWatchIDs.first(where: negotiatingWatchIDs.contains) {
            connectionState = .negotiating(watchID: negotiatingID)
        } else if let connectingID = connectingWatchIDs.first {
            connectionState = .connecting(watchID: connectingID)
        } else if let primary = activeConnections.first {
            connectionState = .connected(primary.watch)
        } else if let reconnecting = connections.first(where: { $0.phase == .reconnecting }) {
            connectionState = .reconnecting(watchID: reconnecting.watch.id)
        } else if isScanning {
            connectionState = .scanning
        } else if let error = lastConnectionError {
            connectionState = .failed(error)
        } else {
            connectionState = .idle
        }
    }

    /// Drops the work a watch was in the middle of when its link went, and the
    /// library operation that was driving it.
    func clearBusyOperationState(on connection: WatchConnection) {
        connection.cancelApplicationFetch()
        connection.endTransfer()
        applications.managementOperation = nil
        applications.managementFeedback = nil
    }

    func handleEvent(_ event: WatchClientEvent, from connection: WatchConnection) {
        switch event {
        case .watchUpdated(let device):
            let needsResync = connection.consumePostReconnectSync()
            refreshConnectionState()
            Task { [weak self] in
                await self?.trackChargeLevel(of: device)
                await self?.recordConnectedWatch(device)
            }
            guard needsResync else { return }
            Task { [weak self] in
                await self?.synchronizeEverything(on: connection)
            }
        case .appFetchRequested(let request):
            beginHandlingAppFetchRequest(request, from: connection)
        case .appMessageReceived(let message):
            Task { [weak self] in await self?.handleAppMessage(message, from: connection) }
        case .transferProgress:
            break
        case .reconnecting:
            refreshConnectionState()
            needsApplicationSynchronization = true
            // Operations interrupted by the drop would otherwise leave the
            // app-management UI busy forever.
            clearBusyOperationState(on: connection)
        case .disconnected(let error):
            connections.removeAll { $0 === connection }
            // The charge story starts over with the next connect: a level
            // remembered across the gap could be from before a night off the
            // wrist, and "it reached 100 since I last looked" is not the same
            // fact as "it just finished charging".
            chargeLevels.removeValue(forKey: connection.watch.id)
            chargeNotified.remove(connection.watch.id)
            lastConnectionError = error
            // On the watch's own screen, where its Connect button is.
            connectionFailures[connection.watch.id] = error
            refreshConnectionState()
            needsApplicationSynchronization = true
            clearBusyOperationState(on: connection)
        case .healthSyncCompleted(let succeeded):
            health.feedback = succeeded
                ? .success("Health synchronization completed.")
                : .failure("The watch rejected health synchronization.")
        case .healthSamplesReceived(let samples):
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.health.samples = try await self.healthStore.merge(samples)
                } catch {
                    self.health.feedback = .failure("Watch health data could not be saved.")
                    return
                }
                self.health.feedback = .success("Received \(samples.count) health update(s) from the watch.")
                #if os(iOS)
                do {
                    // The watch answered on its own account, so this must not raise the
                    // permission sheet.
                    try await self.healthKitBridge.synchronize(
                        self.health.samples,
                        authorization: .onlyWhatIsAlreadyGranted
                    )
                } catch HealthKitBridgeError.notGranted, HealthKitBridgeError.unavailable {
                } catch {
                    self.health.feedback = .failure("The watch's health data was saved, but Apple Health did not accept it.")
                }
                #endif
            }
        case .appRunStateChanged(let event):
            switch event {
            case .started(let id):
                if applications.watchfaces.contains(where: { $0.id == id }) {
                    applications.activeWatchfaceID = id
                    Defaults[.activeWatchfaceID] = id
                }
            case .stopped(let id):
                if applications.activeWatchfaceID == id { applications.activeWatchfaceID = nil }
            }
        case .timelineActionInvoked(let invocation):
            Task { [weak self] in
                guard let self,
                      let index = self.timeline.pins.firstIndex(where: { $0.id == invocation.itemID })
                else { return }
                self.timeline.pins.remove(at: index)
                try? await self.timelineStore.save(self.timeline.pins)
                // Only the watch the action was taken on removed the pin for itself, and
                // the pin is about to be gone from `timeline.pins` for good.
                try? await self.queueTimelineOperation(.delete(invocation.itemID))
                await self.synchronizeTimeline()
                self.timeline.feedback = .success("Timeline action completed.")
            }
        case .applicationLogReceived(let applicationID, let line):
            recordApplicationLogLine(line, from: applicationID)
        case .imageRequested(let request):
            Task { [weak self] in
                await self?.answerImageRequest(request, on: connection)
            }
        }
    }

    // A watch running its recovery firmware rejects every endpoint this uses
    // and drops the link a few seconds after connecting.
    func synchronizeEverything(on connection: WatchConnection) async {
        if connection.watch.isRunningRecoveryFirmware {
            watches.feedback = .failure(
                "This watch started its recovery firmware. It works again once PebbleOS is installed."
            )
            await PebbleDiagnostics.shared.record(
                .error,
                category: "connection",
                message: "Skipping synchronization: the watch is in recovery firmware"
            )
            await resumePendingFirmwareUpdate(on: connection)
            return
        }
        musicCoordinator.watchConnected()
        await synchronizeNotificationSourceApps(on: connection)
        await synchronizeApplications(on: connection)
        try? await connection.client.send(AppRunStateCodec.requestFrame())
        await flushPendingNotifications()
        await flushPendingAppMessages()
        await synchronizeTimeline()
        await synchronizeReminders(on: connection)
        await synchronizeCalendarReminders(on: connection)
        await synchronizeWatchSettings(on: connection)
        await synchronizeApplicationLogging(on: connection)
        // A stale forecast is renewed first, so the watch that just arrived is
        // not handed yesterday's weather and left with it until the next tick.
        await refreshWeatherIfStale()
        await sendWeather(to: connection)
        await requestHealthSync(on: connection)
        // After the applications, which is what says whether the watch has the
        // app a glance belongs to.
        await synchronizeAppGlances(on: connection)
        await resumePendingFirmwareUpdate(on: connection)
        // Last: everything above is for this connection, and a network round
        // trip to GitHub should not hold any of it up.
        await checkFirmwareUpdateUnattended(on: connection)
    }

}

public enum ApplicationManagementError: Error, Equatable, Sendable {
    case missingStoredPackage(String)
    case applicationIDMismatch
}
