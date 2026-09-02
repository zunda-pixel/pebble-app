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
    public internal(set) var connectionState: PebbleConnectionState = .idle
    public internal(set) var connections: [WatchConnection] = []
    public internal(set) var connectingDeviceIDs: Set<String> = []
    /// Why the last attempt at each watch ended. A watch has its own screen with
    /// its own Connect button, and a failure that only reached the log left that
    /// button looking like it had done nothing.
    public internal(set) var connectionFailures: [String: PebbleConnectionError] = [:]
    public internal(set) var isScanning = false
    public internal(set) var discoveredDevices: [DiscoveredPebble] = []
    public internal(set) var watchApplications: [PebbleApplication] = []
    public internal(set) var watchfaces: [PebbleApplication] = []
    public internal(set) var activeWatchfaceID: UUID?
    public internal(set) var favoriteWatchfaceIDs: Set<UUID> = []
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
    public internal(set) var configurationApplication: PebbleApplication?
    public internal(set) var configurationURL: URL?
    public internal(set) var diagnosticReportURL: URL?
    public internal(set) var companionNotificationsEnabled = true
    public internal(set) var notificationStatusMessage: LocalizedStringKey?
    public internal(set) var notificationPreferences = NotificationDeliveryPreferences()
    /// Newest first. Only the notifications this app sent: another phone app's
    /// go to the watch over ANCS, where no app can see them.
    public internal(set) var sentNotifications: [SentNotification] = []
    public internal(set) var savedWatches: [SavedPebbleWatch] = []
    public internal(set) var unknownBondedWatches: [UnknownBondedWatch] = []
    public internal(set) var watchManagementErrorMessage: LocalizedStringKey?
    /// What each watch was last told to do to itself, until it comes back. A
    /// restart says nothing on its way out and nothing on its way in, so the
    /// only news the reader gets is the link returning.
    public internal(set) var watchResetStatusMessages: [String: LocalizedStringKey] = [:]
    public internal(set) var timelinePins: [PebbleTimelinePin] = []
    public internal(set) var reminders: [PebbleTimelinePin] = []
    public internal(set) var reminderStatusMessage: LocalizedStringKey?
    public internal(set) var watchSettings: [String: Bool] = [:]
    public internal(set) var activitySettings = PebbleActivitySettings()
    public internal(set) var heartRateSettings = PebbleHeartRateSettings()
    public internal(set) var isReminderAppEnabled = true
    public internal(set) var watchSettingsStatusMessage: LocalizedStringKey?
    public internal(set) var latestScreenshot: PebbleScreenshot?
    public internal(set) var screenshotURL: URL?
    public internal(set) var watchLogLines: [WatchLogLine] = []
    public internal(set) var watchLogsURL: URL?
    public internal(set) var applicationLogLines: [WatchLogLine] = []
    public internal(set) var isApplicationLoggingEnabled = false
    public internal(set) var coredumpURL: URL?
    public internal(set) var isTakingScreenshot = false
    public internal(set) var isGatheringWatchLogs = false
    public internal(set) var isCollectingCoredump = false
    public internal(set) var watchDiagnosticsStatusMessage: LocalizedStringKey?
    public internal(set) var healthSamples: [PebbleHealthSample] = []
    public internal(set) var catalogApplications: [PebbleCatalogApplication] = []
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
    public internal(set) var weatherReports: [PebbleWeatherReport] = []
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
    public internal(set) var appGlances: [PebbleAppGlance] = []
    public internal(set) var installedApplicationIDsByWatch: [String: Set<UUID>] = [:]

    public var isScanningOrConnecting: Bool {
        switch connectionState {
        case .scanning, .connecting:
            true
        default:
            false
        }
    }

    public var connectedDevices: [PebbleDevice] {
        activeConnections.map(\.device)
    }

    public var connectedDevice: PebbleDevice? {
        activeConnections.first?.device
    }

    var activeConnections: [WatchConnection] {
        connections.filter(\.isConnected)
    }

    /// What one watch is being sent, for the screen showing that watch.
    ///
    /// Named rather than found: `connection(for:)` falls back to the first watch
    /// when given nothing, and "whichever watch is first" is not an answer to
    /// "what is this one doing".
    public func applicationTransfer(on deviceID: String) -> ApplicationTransfer? {
        guard let connection = connections.first(where: { $0.device.id == deviceID }),
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

    public func firmwareTransferProgress(on deviceID: String) -> PutBytesTransferProgress? {
        connections.first { $0.device.id == deviceID }?.transferProgress(for: .firmware)
    }

    public func languagePackTransferProgress(on deviceID: String) -> PutBytesTransferProgress? {
        connections.first { $0.device.id == deviceID }?.transferProgress(for: .languagePack)
    }

    /// Whether any watch is being sent an application it asked for. The library
    /// operations wait on this, because they would rewrite the package under a
    /// transfer already reading it.
    public var isHandlingAppFetch: Bool {
        connections.contains { $0.isFetchingApplication }
    }

    func connection(for deviceID: String?) -> WatchConnection? {
        guard let deviceID else {
            return activeConnections.first
        }
        return connections.first { $0.device.id == deviceID }
    }

    let scannerClient: any PebbleClient
    let clientFactory: @MainActor (String) -> any PebbleClient
    let applicationLibrary: PebbleApplicationLibrary
    let watchLibrary: PebbleWatchLibrary
    let timelineLibrary = TimelinePinLibrary()
    let reminderLibrary: TimelinePinLibrary
    let healthLibrary = PebbleHealthLibrary()
    let appCatalog = PebbleAppCatalog()
    let languagePackCatalog = PebbleLanguagePackCatalog()
    let weatherBridge = WeatherBridge()
    // Held as a function so a test can answer for some places and refuse for
    // others, which WeatherKit itself cannot be asked to produce.
    @ObservationIgnored
    var fetchWeatherReport: (WeatherPlace, Bool) async throws -> PebbleWeatherReport = {
        place, usesFahrenheit in
        try await WeatherBridge().report(for: place, inFahrenheit: usesFahrenheit)
    }
    let phoneLocationSource = PhoneLocationSource()
    let pendingNotificationLibrary = PendingNotificationLibrary()
    let sentNotificationLibrary = SentNotificationLibrary()
    let notificationPreferenceLibrary = NotificationPreferenceLibrary()
    let pendingTimelineOperationLibrary = PendingTimelineOperationLibrary()
    let pendingAppMessageLibrary = PendingAppMessageLibrary()
    let pendingFirmwareUpdateLibrary = PendingFirmwareUpdateLibrary()
    let firmwareCatalog = PebbleOSFirmwareCatalog()
    var pendingAppMessages: [StoredAppMessage] = []
    let calendarBridge = CalendarBridge()
    @ObservationIgnored var calendarChangesTask: Task<Void, Never>?
    #if os(iOS)
    let healthKitBridge = HealthKitBridge()
    #endif
    let notificationSourceAppLibrary = NotificationSourceAppLibrary()
    let appGlanceLibrary: AppGlanceLibrary
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
    @ObservationIgnored var lastConnectionError: PebbleConnectionError?
    @ObservationIgnored var firmwareUpdateTask: Task<Void, any Error>?
    @ObservationIgnored var hasLoadedApplications = false
    @ObservationIgnored var pendingImportSnapshots: [UUID: PebbleApplicationLibrarySnapshot] = [:]
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
            guard let self else { throw PebbleConnectionError.disconnected }
            try await self.sendOrQueueAppMessage(applicationID: applicationID, tuples: tuples)
        },
        notificationHandler: { [weak self] application, title, body in
            guard let self else { throw PebbleConnectionError.disconnected }
            try await self.sendCompanionNotification(
                application: application,
                title: title,
                body: body
            )
        },
        activeWatchHandler: { [weak self] in self?.connectedDevice }
    )

    public init(
        client: any PebbleClient,
        applicationLibrary: PebbleApplicationLibrary = PebbleApplicationLibrary(),
        watchLibrary: PebbleWatchLibrary = PebbleWatchLibrary(),
        appGlanceLibrary: AppGlanceLibrary = AppGlanceLibrary(),
        reminderLibrary: TimelinePinLibrary = TimelinePinLibrary(
            fileURL: URL.applicationSupportDirectory.appending(path: "Pebble/reminders.json")
        ),
        clientFactory: (@MainActor (String) -> any PebbleClient)? = nil
    ) {
        self.scannerClient = client
        // Without a factory every connection shares the scanning client, which
        // limits the app to one watch at a time (mock and QEMU transports).
        self.clientFactory = clientFactory ?? { _ in client }
        self.applicationLibrary = applicationLibrary
        self.watchLibrary = watchLibrary
        self.appGlanceLibrary = appGlanceLibrary
        self.reminderLibrary = reminderLibrary
        companionNotificationsEnabled = Defaults[.companionNotificationsEnabled]
        activeWatchfaceID = Defaults[.activeWatchfaceID]
        favoriteWatchfaceIDs = Set(Defaults[.favoriteWatchfaceIDs])
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await loadSavedWatches()
        await restorePendingNotifications()
        notificationPreferences = (try? await notificationPreferenceLibrary.preferences()) ?? NotificationDeliveryPreferences()
        pendingAppMessages = (try? await pendingAppMessageLibrary.messages()) ?? []
        await loadTimeline()
        await loadHealth()
        await loadCatalog()
        firmwareUpdateJournal = try? await pendingFirmwareUpdateLibrary.journal()
        loadDownloadedFirmware()
        loadWeatherPlaces()
        loadWatchSettings()
        notificationSourceApps = (try? await notificationSourceAppLibrary.apps()) ?? []
        sentNotifications = (try? await sentNotificationLibrary.notifications()) ?? []
        await loadAppGlances()
        musicCoordinator.start()
        phoneCallCoordinator.start()
        observeWatchesReconnectingThemselves()
        if savedWatches.contains(where: \.automaticallyConnects) {
            await scan()
        }
        observeCalendarChanges()
    }

    public func applicationDidBecomeActive() async {
        await start()
        await PebbleDiagnostics.shared.record(category: "lifecycle", message: "Application became active")
        if !activeConnections.isEmpty {
            for connection in activeConnections {
                try? await connection.client.synchronizeTime()
            }
            await restorePendingNotifications()
            pendingAppMessages = (try? await pendingAppMessageLibrary.messages()) ?? pendingAppMessages
            await flushPendingNotifications()
            await flushPendingAppMessages()
            await synchronizeTimeline()
        } else if !isScanning, connectingDeviceIDs.isEmpty, connections.isEmpty {
            if savedWatches.contains(where: \.automaticallyConnects) {
                await scan()
            }
        }
    }

    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        if connections.isEmpty, connectingDeviceIDs.isEmpty {
            connectionState = .scanning
        }
        defer {
            isScanning = false
            refreshConnectionState()
        }

        do {
            await loadSavedWatches()
            var devices = try await scannerClient.scan()
            let connectedIDs = Set(connections.map(\.device.id))
            let missingSavedWatches = savedWatches
                .filter { saved in
                    !connectedIDs.contains(saved.id) && !devices.contains { $0.id == saved.id }
                }
                .map { saved in
                    DiscoveredPebble(id: saved.id, name: saved.name, model: saved.model, signalStrength: 0)
                }
            if !missingSavedWatches.isEmpty,
               let retrieved = try? await scannerClient.retrieveKnownDevices(missingSavedWatches) {
                devices.append(contentsOf: retrieved)
            }
            discoveredDevices = devices.filter { !connectedIDs.contains($0.id) }
            refreshConnectionState()
            let automaticTargets = discoveredDevices.filter { discovered in
                savedWatches.contains { $0.id == discovered.id && $0.automaticallyConnects }
            }
            for device in automaticTargets {
                await connect(to: device)
            }
        } catch let error as PebbleConnectionError {
            if connections.isEmpty {
                lastConnectionError = error
            }
        } catch {
            if connections.isEmpty {
                lastConnectionError = .bluetoothUnavailable
            }
        }
    }

    public func connect(to watch: SavedPebbleWatch) async {
        await connect(to: DiscoveredPebble(
            id: watch.id,
            name: watch.name,
            model: watch.model,
            signalStrength: 0
        ))
    }

    public func connect(to device: DiscoveredPebble) async {
        guard !connectingDeviceIDs.contains(device.id),
              !connections.contains(where: { $0.device.id == device.id }) else {
            return
        }
        connectingDeviceIDs.insert(device.id)
        connectionFailures[device.id] = nil
        refreshConnectionState()
        Task { [id = device.id] in
            await PebbleDiagnostics.shared.record(
                category: "connection",
                message: "connect requested for \(id)"
            )
        }
        defer {
            connectingDeviceIDs.remove(device.id)
            refreshConnectionState()
        }

        let connectionClient = clientFactory(device.id)
        do {
            let connectedDevice = try await connectionClient.connect(to: device)
            lastConnectionError = nil
            connectionFailures[device.id] = nil
            let connection = WatchConnection(
                client: connectionClient,
                device: connectedDevice,
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
            discoveredDevices.removeAll { $0.id == device.id }
            unknownBondedWatches.removeAll { $0.id == device.id }
            // Leaving the id here until this function returns would rank the whole
            // post-connect synchronization as "connecting".
            connectingDeviceIDs.remove(device.id)
            refreshConnectionState()
            await recordConnectedWatch(connectedDevice)
            await restorePendingNotifications()
            await PebbleDiagnostics.shared.record(category: "connection", message: "Watch connected")
            await synchronizeEverything(on: connection)
        } catch let error as PebbleConnectionError {
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
        if let connectingID = connectingDeviceIDs.first {
            connectionState = .connecting(deviceID: connectingID)
        } else if let primary = activeConnections.first {
            connectionState = .connected(primary.device)
        } else if let reconnecting = connections.first(where: { $0.phase == .reconnecting }) {
            connectionState = .reconnecting(deviceID: reconnecting.device.id)
        } else if isScanning {
            connectionState = .scanning
        } else if let error = lastConnectionError {
            connectionState = .failed(error)
        } else {
            connectionState = .idle
        }
    }

    #if os(iOS)

    #endif

    /// Drops the work a watch was in the middle of when its link went, and the
    /// library operation that was driving it.
    func clearBusyOperationState(on connection: WatchConnection) {
        connection.cancelApplicationFetch()
        connection.endTransfer()
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
    }

    func handleEvent(_ event: PebbleClientEvent, from connection: WatchConnection) {
        switch event {
        case .deviceUpdated(let device):
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
            connectionFailures[connection.device.id] = error
            refreshConnectionState()
            needsApplicationSynchronization = true
            clearBusyOperationState(on: connection)
        case .healthSyncCompleted(let succeeded):
            dataSyncStatusMessage = succeeded ? "Health synchronization completed." : "The watch rejected health synchronization."
        case .healthSamplesReceived(let samples):
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.healthSamples = try await self.healthLibrary.merge(samples)
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
                try? await self.timelineLibrary.save(self.timelinePins)
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
        if connection.device.isRunningRecoveryFirmware {
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
