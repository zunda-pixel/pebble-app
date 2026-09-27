public import PebbleProtocol
import CoreLocation
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
    var negotiatingWatchIDs: Set<WatchID> = []
    /// Which connect each watch's link is coming up for. A forget or a
    /// disconnect while it is withdraws the attempt, and the link that arrives
    /// afterwards is closed rather than kept.
    @ObservationIgnored var connectionAttempts: [WatchID: UUID] = [:]
    @ObservationIgnored var watchHistoryCouldNotBeSaved = false
    @ObservationIgnored var startup: Task<Void, Never>?
    /// Why the last scan could not look — the radio off or refused. Nothing to
    /// do with any one watch, which is what lets the Add Watch sheet show it
    /// beside a watch's own failure without showing another watch's.
    public internal(set) var scanFailure: WatchConnectionError?
    /// What the banner says went wrong when nothing is connected: the last
    /// scan, connect or link to fail, whichever watch it was.
    var lastConnectionError: WatchConnectionError?

    /// Derived rather than kept: a stored copy had to be refreshed by hand at
    /// every change to what it is made of, and each place that forgot left the
    /// banner saying something that was no longer so.
    public var connectionState: WatchConnectionState {
        // `.negotiating` before `.connecting`: they are one connect at two
        // stages, and the second is the one that takes the seconds.
        if let negotiatingID = connectingWatchIDs.first(where: negotiatingWatchIDs.contains) {
            return .negotiating(watchID: negotiatingID)
        } else if let connectingID = connectingWatchIDs.first {
            return .connecting(watchID: connectingID)
        } else if let primary = activeConnections.first {
            return .connected(primary.watch)
        } else if let reconnecting = connections.first(where: { $0.phase == .reconnecting }) {
            return .reconnecting(watchID: reconnecting.watch.id)
        } else if isScanning {
            return .scanning
        } else if let error = lastConnectionError {
            return .failed(error)
        } else {
            return .idle
        }
    }

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
    public let deepLinks = DeepLinksModel()

    /// Not read off `connectionState`, which answers `.negotiating` for a
    /// link that is up and `.connected` while a second watch is looked for.
    public var isScanningOrConnecting: Bool {
        isScanning || !connectingWatchIDs.isEmpty
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
            name: applications.all.first { $0.id == applicationID }?.displayName,
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
    let appCatalog: ApplicationCatalog
    let languagePackCatalog = LanguagePackCatalog()
    let weatherBridge = WeatherBridge()
    // Held as a function so a test can answer for some places and refuse for
    // others, which WeatherKit itself cannot be asked to produce.
    @ObservationIgnored
    var fetchWeatherReport: (WeatherPlace, CLLocation, Bool) async throws -> WeatherReport = {
        place, location, usesFahrenheit in
        try await WeatherBridge().report(for: place, at: location, inFahrenheit: usesFahrenheit)
    }
    let phoneLocationSource = PhoneLocationSource()
    let pendingNotificationStore: PendingNotificationStore
    let sentNotificationStore: SentNotificationStore
    let notificationPreferenceStore: NotificationPreferenceStore
    let pendingTimelineOperationStore: PendingTimelineOperationStore
    let pendingAppMessageStore: PendingAppMessageStore
    let pendingFirmwareUpdateStore: PendingFirmwareUpdateStore
    let firmwarePackageStore: FirmwarePackageStore
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
    /// The watch whose app the companion script is running for: the one that
    /// launched it or last sent it a message. A reply goes back there, not to
    /// whichever watch happens to be first.
    @ObservationIgnored var companionRuntimeWatchID: WatchID?
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
    let writtenRecordStore: WrittenRecordStore
    let speechBridge = SpeechBridge()
    var voiceTranscriptionReadiness = VoiceTranscriptionReadiness.turnedOff
    /// Every language the phone's recognizer can be asked for, for the
    /// settings picker. Filled beside the readiness, and empty until then.
    var voiceSupportedLanguages: [String] = []
    @ObservationIgnored lazy var musicCoordinator = MusicCoordinator(
        source: makeSystemMusicSource(),
        send: { [weak self] frame in try await self?.broadcast(frame) }
    )
    /// Whether the health data arriving answers the reader's own request.
    @ObservationIgnored var isHealthSyncRequestedByReader = false
    @ObservationIgnored var firmwareUpdateTask: Task<Void, any Error>?
    /// Which `performFirmwareUpdate` call holds the one update that may run.
    /// Taken before its first suspension, where `firmwareUpdateTask` can only be
    /// set after several.
    @ObservationIgnored var firmwareUpdateClaim: UUID?
    /// Which watch the claimed update is for, so stopping one watch's update
    /// cannot end another's.
    @ObservationIgnored var firmwareUpdateWatchID: WatchID?
    @ObservationIgnored var hasLoadedApplications = false
    @ObservationIgnored var pendingImportSnapshots: [UUID: WatchApplicationLibrarySnapshot] = [:]
    @ObservationIgnored var pendingSnapshotExpiries: [UUID: Task<Void, Never>] = [:]
    /// Watches whose applications were not registered when they last could
    /// have been: refused while another operation ran, failed, or dropped
    /// part-way. Per watch, because two watches arriving at once are two
    /// synchronizations, and the second must wait its turn rather than be lost.
    @ObservationIgnored var watchesAwaitingApplicationSynchronization: Set<WatchID> = []
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var recentNotificationFingerprints: [String: Date] = [:]
    @ObservationIgnored var pendingNotifications: [PendingDelivery<TimelineNotification>] = []
    // Both the app coming forward and a watch finishing its synchronization ask
    // for a flush; two at once hand the watch everything twice.
    @ObservationIgnored var pendingNotificationFlush: Task<Void, Never>?
    @ObservationIgnored var pendingAppMessageFlush: Task<Void, Never>?
    /// The last record from one watch being passed on to the others, which the
    /// next one waits behind so that two changes land in the order they were
    /// made.
    @ObservationIgnored var watchDatabaseRelay: Task<Void, Never>?
    @ObservationIgnored lazy var companionRuntime = PebbleCompanionRuntime(
        openURLHandler: { [weak self] url in self?.openConfigurationURL(url) },
        appMessageHandler: { [weak self] applicationID, tuples in
            guard let self else { throw WatchConnectionError.disconnected }
            try await self.sendOrQueueAppMessage(applicationID: applicationID, tuples: tuples)
        },
        notificationHandler: { [weak self] application, title, body in
            await self?.sendCompanionNotification(
                application: application,
                title: title,
                body: body
            )
        },
        activeWatchHandler: { [weak self] in
            self?.companionRuntimeConnection?.watch ?? self?.connectedWatch
        },
        // The same position the weather is fetched for. A script asking for one
        // is asking the phone, because WebKit gives an app no way to grant the
        // web's own `navigator.geolocation`.
        locationHandler: { [weak self] in
            guard let self else { throw WeatherSourceError.locationNotAllowed }
            return try await self.phoneLocationSource.currentLocation()
        },
        // Followed positions for `watchPosition` (#90). Gated on the phone's
        // standing permission and never asking for it: a script's request must
        // not be what raises the OS dialog.
        locationUpdatesHandler: { [weak self] in
            guard let self, self.phoneLocationSource.isAllowed else {
                throw WeatherSourceError.locationNotAllowed
            }
            // `CLLocationUpdate.Updates` cannot be made by hand, which is what
            // a test needs to stand a stream of fixes in — so the fixes travel
            // as a plain stream and the CoreLocation shape stays here.
            let updates = CLLocationUpdate.liveUpdates()
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await update in updates {
                            if let location = update.location {
                                continuation.yield(location)
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        },
        timelinePinInsertHandler: { [weak self] pin, applicationID in
            await self?.insertCompanionTimelinePin(pin, applicationID: applicationID)
        },
        timelinePinDeleteHandler: { [weak self] backingID, applicationID in
            await self?.deleteCompanionTimelinePin(backingID: backingID, applicationID: applicationID)
        },
        appGlanceReloadHandler: { [weak self] slices, applicationID in
            await self?.reloadCompanionAppGlance(slices, applicationID: applicationID) ?? false
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
        appCatalog: ApplicationCatalog? = nil,
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
        self.appCatalog = appCatalog ?? ApplicationCatalog(directory: storageDirectory)
        pendingNotificationStore = PendingNotificationStore(directory: storageDirectory)
        sentNotificationStore = SentNotificationStore(directory: storageDirectory)
        notificationPreferenceStore = NotificationPreferenceStore(directory: storageDirectory)
        pendingTimelineOperationStore = PendingTimelineOperationStore(directory: storageDirectory)
        pendingAppMessageStore = PendingAppMessageStore(directory: storageDirectory)
        pendingFirmwareUpdateStore = PendingFirmwareUpdateStore(directory: storageDirectory)
        firmwarePackageStore = FirmwarePackageStore(directory: storageDirectory)
        notificationSourceAppStore = NotificationSourceAppStore(directory: storageDirectory)
        writtenRecordStore = WrittenRecordStore(directory: storageDirectory)
        notifications.companionEnabled = Defaults[.companionNotificationsEnabled]
        timeline.allDayReminderMinutes = Defaults[.allDayReminderMinutes]
        catalog.source = Defaults[.catalogSource]
    }

    private func loadWhatWasKept() async {
        await loadSavedWatches()
        await restorePendingNotifications()
        notifications.preferences = (try? await notificationPreferenceStore.preferences()) ?? NotificationDeliveryPreferences()
        pendingAppMessages = (try? await pendingAppMessageStore.messages()) ?? []
        await loadTimeline()
        await loadHealth()
        await loadCatalog()
        await loadFirmwareState()
        loadWeatherPlaces()
        loadWatchSettings()
        notifications.sourceApps = (try? await notificationSourceAppStore.apps()) ?? []
        notifications.sent = (try? await sentNotificationStore.notifications()) ?? []
        await loadAppGlances()
    }

    /// Every caller waits for what is on disk to be read — the scene coming
    /// forward and the first view's task arrive together, and the second used
    /// to go on to flush and refresh against a model that had loaded nothing.
    /// Not for the scan after it, which waits for every watch it connects to.
    public func start() async {
        if let startup {
            await startup.value
            return
        }
        guard !hasStarted else { return }
        hasStarted = true
        let startup = Task { await self.loadWhatWasKept() }
        self.startup = startup
        await startup.value
        observeWatchesReconnectingThemselves()
        // A watch that has been set up reconnects on its own, so the radio has
        // to be open before it does — but only where there is a watch to expect.
        // Opening it is what raises the system's Bluetooth dialog, and an
        // install with no watch yet would be asked for permission before it had
        // asked for anything.
        if !watches.saved.isEmpty {
            scannerClient.startBluetooth()
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
        // Last: it waits for every watch it connects to, and nothing above
        // needs a watch.
        if watches.saved.contains(where: \.automaticallyConnects) {
            await scan()
        }
    }

    public func applicationDidBecomeActive() async {
        await start()
        await DiagnosticLog.shared.record(category: "lifecycle", message: "Application became active")
        // Coming to the foreground is one of the few moments iOS promises the
        // app is running, which makes it the reliable one of the staleness
        // triggers.
        await refreshWeatherIfStale()
        if !activeConnections.isEmpty {
            for connection in activeConnections {
                try? await connection.client.synchronizeTime()
            }
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
        var automaticTargets: [DiscoveredWatch] = []
        do {
            await loadSavedWatches()
            // Asking for a watch is the moment the radio is worth its dialog.
            scannerClient.startBluetooth()
            var scanned = try await scannerClient.scan()
            let connectedIDs = Set(connections.map(\.watch.id))
            let missingSavedWatches = watches.saved
                .filter { saved in
                    !connectedIDs.contains(saved.id) && !scanned.contains { $0.id == saved.id }
                }
                .map(\.connectionTarget)
            if !missingSavedWatches.isEmpty,
               let retrieved = try? await scannerClient.retrieveKnownWatches(missingSavedWatches) {
                scanned.append(contentsOf: retrieved)
            }
            discoveredWatches = scanned.filter { !connectedIDs.contains($0.id) }
            scanFailure = nil
            automaticTargets = discoveredWatches.filter { discovered in
                watches.saved.contains { $0.id == discovered.id && $0.automaticallyConnects }
            }
        } catch let error as WatchConnectionError {
            // Another scan already looking is not the radio failing to.
            if error != .scanAlreadyInProgress { scanFailure = error }
            if connections.isEmpty {
                lastConnectionError = error
            }
        } catch {
            scanFailure = .bluetoothUnavailable
            if connections.isEmpty {
                lastConnectionError = .bluetoothUnavailable
            }
        }
        // The scan is over once the watches are found. Held through the
        // connects, it was held through each watch's whole synchronization —
        // a network round trip among it — and the second watch waited for the
        // first's.
        isScanning = false
        let connects = automaticTargets.map { watch in
            Task { await self.connect(to: watch) }
        }
        for connect in connects { await connect.value }
    }

    public func connect(to watch: SavedWatch) async {
        await connect(to: watch.connectionTarget)
    }

    public func connect(to watch: DiscoveredWatch) async {
        await connect(to: watch.connectionTarget)
    }

    public func connect(to watch: WatchConnectionTarget) async {
        guard !connectingWatchIDs.contains(watch.id),
              !connections.contains(where: { $0.watch.id == watch.id }) else {
            return
        }
        connectingWatchIDs.insert(watch.id)
        connectionFailures[watch.id] = nil
        let attempt = UUID()
        connectionAttempts[watch.id] = attempt
        Task { [id = watch.id] in
            await DiagnosticLog.shared.record(
                category: "connection",
                message: "connect requested for \(id)"
            )
        }
        defer {
            connectingWatchIDs.remove(watch.id)
            negotiatingWatchIDs.remove(watch.id)
            if connectionAttempts[watch.id] == attempt { connectionAttempts[watch.id] = nil }
        }

        let connectionClient = clientFactory(watch.id)
        do {
            let connectedWatch = try await connectionClient.connect(to: watch) { [weak self] _ in
                // Both phases mean the same thing to a screen: the link is up
                // and the watch has not finished answering. They are reported
                // separately because a watch that reaches the first and never
                // the second is one whose protocol service is unusable, and
                // the log needs to tell those apart.
                guard let self else { return }
                self.negotiatingWatchIDs.insert(watch.id)
            }
            // Forgotten or disconnected while the link was coming up: saving it
            // now would bring back the watch the reader just let go of.
            guard connectionAttempts[watch.id] == attempt else {
                await connectionClient.disconnect(from: connectedWatch)
                return
            }
            lastConnectionError = nil
            connectionFailures[watch.id] = nil
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
            discoveredWatches.removeAll { $0.id == watch.id }
            watches.unknownBonded.removeAll { $0.id == watch.id }
            // Leaving the id here until this function returns would rank the whole
            // post-connect synchronization as "connecting".
            connectingWatchIDs.remove(watch.id)
            await recordConnectedWatch(connectedWatch)
            await DiagnosticLog.shared.record(category: "connection", message: "Watch connected")
            await synchronizeEverything(on: connection)
        } catch let error as WatchConnectionError {
            guard connectionAttempts[watch.id] == attempt else { return }
            lastConnectionError = error
            connectionFailures[watch.id] = error
            if !connections.isEmpty {
                watches.feedback = .failure(error.message)
            }
            await DiagnosticLog.shared.record(.error, category: "connection", message: error.logDescription)
        } catch {
            guard connectionAttempts[watch.id] == attempt else { return }
            lastConnectionError = .protocolNegotiationFailed
            connectionFailures[watch.id] = .protocolNegotiationFailed
        }
    }

    /// Drops the work a watch was in the middle of when its link went, and the
    /// library operation that was driving it.
    func clearBusyOperationState(on connection: WatchConnection) {
        connection.cancelApplicationFetch()
        connection.endTransfer()
        watchesAwaitingApplicationSynchronization.insert(connection.watch.id)
        guard let owned = connection.ownedApplicationOperation else { return }
        connection.ownedApplicationOperation = nil
        if applications.managementOperation == owned {
            applications.managementOperation = nil
            applications.managementFeedback = nil
        }
    }

    func handleEvent(_ event: WatchClientEvent, from connection: WatchConnection) {
        switch event {
        case .watchUpdated(let watch):
            let needsResync = connection.consumePostReconnectSync()
            Task { [weak self] in
                await self?.trackChargeLevel(of: watch)
                await self?.recordConnectedWatch(watch)
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
            // Operations interrupted by the drop would otherwise leave the
            // app-management UI busy forever.
            clearBusyOperationState(on: connection)
            if activeConnections.isEmpty { musicCoordinator.watchDisconnected() }
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
            clearBusyOperationState(on: connection)
            if activeConnections.isEmpty { musicCoordinator.watchDisconnected() }
        case .healthSyncCompleted(let succeeded):
            Task { [weak self] in
                guard let self else { return }
                await self.reportHealth(
                    succeeded
                        ? .success("Health synchronization completed.")
                        : .failure("The watch rejected health synchronization."),
                    logging: succeeded ? "synchronization completed" : "the watch rejected synchronization"
                )
                self.isHealthSyncRequestedByReader = false
            }
        case .healthSamplesReceived(let samples):
            Task { [weak self] in
                guard let self else { return }
                // What the watch actually sent, on the diagnostics report so a
                // reader can tell "the watch measured nothing" from "the app
                // dropped it" — the heart rate and blood oxygen especially,
                // which only appear once their sensor has run.
                let spo2Days = samples.filter { $0.bloodOxygen != nil }.count
                let spo2Readings = samples.reduce(0) { $0 + $1.bloodOxygenReadings.count }
                let hrReadings = samples.reduce(0) { $0 + $1.heartRateReadings.count }
                await DiagnosticLog.shared.record(
                    category: "health",
                    message: "received \(samples.count) day(s): "
                        + "\(spo2Days) with SpO2 (\(spo2Readings) readings), \(hrReadings) HR readings"
                )
                do {
                    self.health.samples = try await self.healthStore.merge(samples)
                } catch {
                    await self.reportHealth(
                        .failure("Watch health data could not be saved."),
                        logging: "the received health data could not be saved: \(String(reflecting: error))"
                    )
                    return
                }
                await self.reportHealth(
                    .success("Received \(samples.count) health updates from the watch."),
                    logging: "saved \(samples.count) day(s) from the watch"
                )
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
                    await self.reportHealth(
                        .failure("The watch's health data was saved, but Apple Health did not accept it."),
                        logging: "Apple Health did not accept the watch's data: \(String(reflecting: error))"
                    )
                }
                #endif
            }
        case .appRunStateChanged(let event):
            switch event {
            case .started(let id):
                if applications.watchfaces.contains(where: { $0.id == id }) {
                    applications.activeWatchfaceIDs[connection.watch.id] = id
                }
                // The PKJS lifecycle ties the script's life to the app's run,
                // so a launch is what makes `ready` fire — every launch, not
                // only the first (#130).
                Task { [weak self] in
                    await self?.launchCompanionRuntime(applicationID: id, on: connection.watch.id)
                    // What was queued for this app was refused while it was not
                    // running; now it is.
                    if self?.pendingAppMessages.contains(where: { $0.applicationID == id }) == true {
                        await self?.flushPendingAppMessages()
                    }
                }
            case .stopped(let id):
                if applications.activeWatchfaceIDs[connection.watch.id] == id {
                    applications.activeWatchfaceIDs[connection.watch.id] = nil
                }
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
        case .applicationLogReceived(let logLine):
            recordApplicationLogLine(logLine.line, from: logLine.applicationID)
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
            await DiagnosticLog.shared.record(
                .error,
                category: "connection",
                message: "Skipping synchronization: the watch is in recovery firmware"
            )
            await resumePendingFirmwareUpdate(on: connection)
            return
        }
        musicCoordinator.watchConnected()
        await synchronizeNotificationSourceApps(on: connection)
        // Once per link rather than on every synchronization: the flag is
        // read from the version the watch gave as the link came up, and
        // stays set on the watch until something clears a database.
        if connection.watch.version.isUnfaithful {
            try? await applicationLibrary.forgetWrittenApplicationDigests(watchID: connection.watch.id)
        }
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
