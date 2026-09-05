public import PebbleProtocol
import Defaults
public import Foundation
import Observation
public import SwiftUI

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
    public internal(set) var connectingWatchIDs: Set<WatchID> = []
    /// Why the last attempt at each watch ended. A watch has its own screen with
    /// its own Connect button, and a failure that only reached the log left that
    /// button looking like it had done nothing.
    public internal(set) var connectionFailures: [WatchID: WatchConnectionError] = [:]
    public internal(set) var isScanning = false
    public internal(set) var discoveredWatches: [DiscoveredWatch] = []
    public internal(set) var watchApplications: [WatchApplication] = []
    public internal(set) var watchfaces: [WatchApplication] = []
    public internal(set) var activeWatchfaceID: UUID?
    public internal(set) var isLoadingApplications = false
    public internal(set) var isImportingApplication = false
    public internal(set) var applicationLibraryErrorMessage: LocalizedStringKey?
    /// The library operations — importing, removing, reordering, synchronizing —
    /// are phone-side and take turns: each rewrites the one library and then
    /// pushes it to every watch, so this stays a single value rather than moving
    /// onto a connection. What belongs to a watch is the transfer, and that lives
    /// on `WatchConnection`.
    public internal(set) var applicationManagementOperation: ApplicationManagementOperation?
    public internal(set) var applicationManagementStatusMessage: LocalizedStringKey?
    public internal(set) var configurationApplication: WatchApplication?
    public internal(set) var configurationURL: URL?
    public internal(set) var diagnosticReportURL: URL?
    public internal(set) var companionNotificationsEnabled = true
    public internal(set) var notificationStatusMessage: LocalizedStringKey?
    public internal(set) var notificationPreferences = NotificationDeliveryPreferences()
    /// Newest first. Only the notifications this app sent: another phone app's
    /// go to the watch over ANCS, where no app can see them.
    public internal(set) var sentNotifications: [SentNotification] = []
    public internal(set) var savedWatches: [SavedWatch] = []
    public internal(set) var unknownBondedWatches: [UnknownBondedWatch] = []
    public internal(set) var watchManagementErrorMessage: LocalizedStringKey?
    /// What each watch was last told to do to itself, until it comes back. A
    /// restart says nothing on its way out and nothing on its way in, so the
    /// only news the reader gets is the link returning.
    public internal(set) var watchResetStatusMessages: [WatchID: LocalizedStringKey] = [:]
    public internal(set) var timelinePins: [TimelinePin] = []
    public internal(set) var reminders: [TimelinePin] = []
    public internal(set) var reminderStatusMessage: LocalizedStringKey?
    public internal(set) var watchSettings: [String: Bool] = [:]
    public internal(set) var activitySettings = ActivitySettings()
    public internal(set) var heartRateSettings = HeartRateSettings()
    public internal(set) var isReminderAppEnabled = true
    public internal(set) var watchSettingsStatusMessage: LocalizedStringKey?
    public internal(set) var latestScreenshot: WatchScreenshot?
    public internal(set) var screenshotURL: URL?
    public internal(set) var watchLogLines: [WatchLogLine] = []
    public internal(set) var watchLogsURL: URL?
    public internal(set) var applicationLogLines: [WatchLogLine] = []
    public internal(set) var isApplicationLoggingEnabled = false
    public internal(set) var coredumpURL: URL?
    public internal(set) var isTakingScreenshot = false
    public internal(set) var isGatheringWatchLogs = false
    public internal(set) var isCollectingCoredump = false
    public internal(set) var watchDiagnosticsStatusMessages: [WatchDiagnostic: LocalizedStringKey] = [:]
    public internal(set) var healthSamples: [WatchHealthSample] = []
    public internal(set) var catalogApplications: [CatalogApplication] = []
    public internal(set) var catalogLastUpdated: Date?
    public internal(set) var isUpdatingCatalog = false
    public internal(set) var installingCatalogApplicationID: UUID?
    public internal(set) var firmwareUpdateStatusMessage: LocalizedStringKey?
    public internal(set) var firmwareUpdateJournal: FirmwareUpdateJournal?
    public internal(set) var firmwareRequiresConfirmation = false
    public internal(set) var availableFirmwareRelease: PebbleOSFirmwareRelease?
    public internal(set) var downloadedFirmware: DownloadedFirmware?
    public internal(set) var languageStatusMessage: LocalizedStringKey?
    public internal(set) var isInstallingLanguagePack = false
    public internal(set) var weatherPlaces: [WeatherPlace] = []
    public internal(set) var weatherReports: [WeatherReport] = []
    public internal(set) var weatherCredit: WeatherCredit?
    public internal(set) var weatherUpdated: Date?
    public internal(set) var weatherUsesFahrenheit = false
    public internal(set) var isRefreshingWeather = false
    public internal(set) var weatherStatusMessage: LocalizedStringKey?
    public internal(set) var dataSyncStatusMessage: LocalizedStringKey?
    public internal(set) var timelineActionStatusMessage: LocalizedStringKey?
    public internal(set) var healthExportURL: URL?
    public internal(set) var notificationSourceApps: [NotificationSourceApp] = []
    /// The line each watchapp shows in the launcher, for the apps that have one.
    public internal(set) var appGlances: [AppGlance] = []
    public internal(set) var installedApplicationIDsByWatch: [WatchID: Set<UUID>] = [:]

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
            name: (watchApplications + watchfaces).first { $0.id == applicationID }?.displayName,
            progress: progress
        )
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
    let timelineStore = TimelinePinStore()
    let reminderStore: TimelinePinStore
    let healthStore = WatchHealthStore()
    let appCatalog = AppCatalog()
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
    let pendingNotificationStore = PendingNotificationStore()
    let sentNotificationStore = SentNotificationStore()
    let notificationPreferenceStore = NotificationPreferenceStore()
    let pendingTimelineOperationStore = PendingTimelineOperationStore()
    let pendingAppMessageStore = PendingAppMessageStore()
    let pendingFirmwareUpdateStore = PendingFirmwareUpdateStore()
    let firmwareCatalog = PebbleOSFirmwareCatalog()
    var pendingAppMessages: [StoredAppMessage] = []
    let calendarBridge = CalendarBridge()
    // Held behind its protocol so a test can answer for the Reminders app,
    // which nothing can write to without a person saying yes to it first.
    @ObservationIgnored var remindersAppStore: any RemindersAppStore = RemindersBridge()
    @ObservationIgnored var calendarChangesTask: Task<Void, Never>?
    #if os(iOS)
    let healthKitBridge = HealthKitBridge()
    #endif
    let notificationSourceAppStore = NotificationSourceAppStore()
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
        activeWatchHandler: { [weak self] in self?.connectedWatch }
    )

    public init(
        client: any WatchClient,
        applicationLibrary: WatchApplicationLibrary = WatchApplicationLibrary(),
        watchStore: SavedWatchStore = SavedWatchStore(),
        appGlanceStore: AppGlanceStore = AppGlanceStore(),
        reminderStore: TimelinePinStore = TimelinePinStore(
            fileURL: URL.applicationSupportDirectory.appending(path: "Pebble/reminders.json")
        ),
        clientFactory: (@MainActor (WatchID) -> any WatchClient)? = nil
    ) {
        self.scannerClient = client
        // Without a factory every connection shares the scanning client, which
        // limits the app to one watch at a time (mock and QEMU transports).
        self.clientFactory = clientFactory ?? { _ in client }
        self.applicationLibrary = applicationLibrary
        self.watchStore = watchStore
        self.appGlanceStore = appGlanceStore
        self.reminderStore = reminderStore
        companionNotificationsEnabled = Defaults[.companionNotificationsEnabled]
        activeWatchfaceID = Defaults[.activeWatchfaceID]
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await loadSavedWatches()
        await restorePendingNotifications()
        notificationPreferences = (try? await notificationPreferenceStore.preferences()) ?? NotificationDeliveryPreferences()
        pendingAppMessages = (try? await pendingAppMessageStore.messages()) ?? []
        await loadTimeline()
        await loadHealth()
        await loadCatalog()
        firmwareUpdateJournal = try? await pendingFirmwareUpdateStore.journal()
        loadDownloadedFirmware()
        loadWeatherPlaces()
        loadWatchSettings()
        notificationSourceApps = (try? await notificationSourceAppStore.apps()) ?? []
        sentNotifications = (try? await sentNotificationStore.notifications()) ?? []
        await loadAppGlances()
        musicCoordinator.start()
        phoneCallCoordinator.start()
        observeWatchesReconnectingThemselves()
        // A watch that has been set up reconnects on its own, so the radio has
        // to be open before it does — but only where there is a watch to expect.
        // Opening it is what raises the system's Bluetooth dialog, and an
        // install with no watch yet would be asked for permission before it had
        // asked for anything.
        if !savedWatches.isEmpty {
            scannerClient.startBluetooth()
        }
        if savedWatches.contains(where: \.automaticallyConnects) {
            await scan()
        }
        observeEventKitChanges()
    }

    public func applicationDidBecomeActive() async {
        await start()
        await PebbleDiagnostics.shared.record(category: "lifecycle", message: "Application became active")
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
            if savedWatches.contains(where: \.automaticallyConnects) {
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
            let missingSavedWatches = savedWatches
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
                savedWatches.contains { $0.id == discovered.id && $0.automaticallyConnects }
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
            refreshConnectionState()
        }

        let connectionClient = clientFactory(device.id)
        do {
            let connectedWatch = try await connectionClient.connect(to: device)
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
            unknownBondedWatches.removeAll { $0.id == device.id }
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
                watchManagementErrorMessage = error.message
            }
            await PebbleDiagnostics.shared.record(.error, category: "connection", message: error.logDescription)
        } catch {
            lastConnectionError = .protocolNegotiationFailed
            connectionFailures[device.id] = .protocolNegotiationFailed
        }
    }

    func refreshConnectionState() {
        if let connectingID = connectingWatchIDs.first {
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
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
    }

    func handleEvent(_ event: WatchClientEvent, from connection: WatchConnection) {
        switch event {
        case .watchUpdated(let device):
            let needsResync = connection.consumePostReconnectSync()
            refreshConnectionState()
            Task { [weak self] in
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
            lastConnectionError = error
            // On the watch's own screen, where its Connect button is.
            connectionFailures[connection.watch.id] = error
            refreshConnectionState()
            needsApplicationSynchronization = true
            clearBusyOperationState(on: connection)
        case .healthSyncCompleted(let succeeded):
            dataSyncStatusMessage = succeeded ? "Health synchronization completed." : "The watch rejected health synchronization."
        case .healthSamplesReceived(let samples):
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.healthSamples = try await self.healthStore.merge(samples)
                } catch {
                    self.dataSyncStatusMessage = "Watch health data could not be saved."
                    return
                }
                self.dataSyncStatusMessage = "Received \(samples.count) health update(s) from the watch."
                #if os(iOS)
                do {
                    // The watch answered on its own account, so this must not raise the
                    // permission sheet.
                    try await self.healthKitBridge.synchronize(
                        self.healthSamples,
                        authorization: .onlyWhatIsAlreadyGranted
                    )
                } catch HealthKitBridgeError.notGranted, HealthKitBridgeError.unavailable {
                } catch {
                    self.dataSyncStatusMessage = "The watch's health data was saved, but Apple Health did not accept it."
                }
                #endif
            }
        case .appRunStateChanged(let event):
            switch event {
            case .started(let id):
                if watchfaces.contains(where: { $0.id == id }) {
                    activeWatchfaceID = id
                    Defaults[.activeWatchfaceID] = id
                }
            case .stopped(let id):
                if activeWatchfaceID == id { activeWatchfaceID = nil }
            }
        case .timelineActionInvoked(let invocation):
            Task { [weak self] in
                guard let self,
                      let index = self.timelinePins.firstIndex(where: { $0.id == invocation.itemID })
                else { return }
                self.timelinePins.remove(at: index)
                try? await self.timelineStore.save(self.timelinePins)
                // Only the watch the action was taken on removed the pin for itself, and
                // the pin is about to be gone from `timelinePins` for good.
                try? await self.queueTimelineOperation(.delete(invocation.itemID))
                await self.synchronizeTimeline()
                self.timelineActionStatusMessage = "Timeline action completed."
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
            watchManagementErrorMessage =
                "This watch started its recovery firmware. It works again once PebbleOS is installed."
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
        await synchronizeWatchSettings(on: connection)
        await synchronizeApplicationLogging(on: connection)
        await sendWeather(to: connection)
        await requestHealthSync(on: connection)
        // After the applications, which is what says whether the watch has the
        // app a glance belongs to.
        await synchronizeAppGlances(on: connection)
        await resumePendingFirmwareUpdate(on: connection)
    }

}

public enum ApplicationManagementError: Error, Equatable, Sendable {
    case missingStoredPackage(String)
    case applicationIDMismatch
}
