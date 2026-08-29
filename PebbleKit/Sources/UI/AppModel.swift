public import API
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
    public internal(set) var isScanning = false
    public internal(set) var discoveredDevices: [DiscoveredPebble] = []
    public internal(set) var watchApplications: [PebbleApplication] = []
    public internal(set) var watchfaces: [PebbleApplication] = []
    public internal(set) var activeWatchfaceID: UUID?
    public internal(set) var favoriteWatchfaceIDs: Set<UUID> = []
    public internal(set) var isLoadingApplications = false
    public internal(set) var isImportingApplication = false
    public internal(set) var applicationLibraryErrorMessage: LocalizedStringKey?
    public internal(set) var installingApplicationID: UUID?
    public internal(set) var installingApplicationName: String?
    public internal(set) var installationProgress: PutBytesTransferProgress?
    public internal(set) var applicationManagementOperation: ApplicationManagementOperation?
    public internal(set) var applicationManagementStatusMessage: LocalizedStringKey?
    public internal(set) var isHandlingAppFetch = false
    public internal(set) var configurationApplication: PebbleApplication?
    public internal(set) var configurationURL: URL?
    public internal(set) var diagnosticReportURL: URL?
    public internal(set) var companionNotificationsEnabled = true
    public internal(set) var notificationStatusMessage: LocalizedStringKey?
    public internal(set) var notificationPreferences = NotificationDeliveryPreferences()
    public internal(set) var savedWatches: [SavedPebbleWatch] = []
    public internal(set) var watchManagementErrorMessage: LocalizedStringKey?
    public internal(set) var watchResetStatusMessage: LocalizedStringKey?
    public internal(set) var timelinePins: [PebbleTimelinePin] = []
    public internal(set) var healthSamples: [PebbleHealthSample] = []
    public internal(set) var catalogApplications: [PebbleCatalogApplication] = []
    public internal(set) var catalogLastUpdated: Date?
    public internal(set) var isUpdatingCatalog = false
    public internal(set) var installingCatalogApplicationID: UUID?
    public internal(set) var firmwareUpdateStatusMessage: LocalizedStringKey?
    public internal(set) var firmwareUpdateJournal: FirmwareUpdateJournal?
    public internal(set) var firmwareRequiresConfirmation = false
    public internal(set) var firmwareUpdateProgress: PutBytesTransferProgress?
    public internal(set) var availableFirmwareRelease: PebbleOSFirmwareRelease?
    public internal(set) var dataSyncStatusMessage: LocalizedStringKey?
    public internal(set) var timelineActionStatusMessage: LocalizedStringKey?
    public internal(set) var healthExportURL: URL?
    public internal(set) var notificationSourceApps: [NotificationSourceApp] = []
    /// Application IDs known to be registered on each watch, keyed by watch ID.
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

    /// The primary watch: the first connected one. Flows that can only target
    /// a single watch (PBW configuration pages, the catalog compatibility
    /// filter) use it.
    public var connectedDevice: PebbleDevice? {
        activeConnections.first?.device
    }

    var activeConnections: [WatchConnection] {
        connections.filter(\.isConnected)
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
    let healthLibrary = PebbleHealthLibrary()
    let appCatalog = PebbleAppCatalog()
    let pendingNotificationLibrary = PendingNotificationLibrary()
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
    @ObservationIgnored var appFetchTask: Task<Void, Never>?
    @ObservationIgnored var hasLoadedApplications = false
    @ObservationIgnored var pendingImportSnapshots: [UUID: PebbleApplicationLibrarySnapshot] = [:]
    @ObservationIgnored var needsApplicationSynchronization = false
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored var recentNotificationFingerprints: [String: Date] = [:]
    @ObservationIgnored var pendingNotifications: [PebbleTimelineNotification] = []
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
        clientFactory: (@MainActor (String) -> any PebbleClient)? = nil
    ) {
        self.scannerClient = client
        // Without a factory every connection shares the scanning client, which
        // limits the app to one watch at a time (mock and QEMU transports).
        self.clientFactory = clientFactory ?? { _ in client }
        self.applicationLibrary = applicationLibrary
        self.watchLibrary = watchLibrary
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
        notificationSourceApps = (try? await notificationSourceAppLibrary.apps()) ?? []
        musicCoordinator.start()
        phoneCallCoordinator.start()
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
            // Bonded watches do not advertise, so scanning alone never finds
            // them again; look the saved ones up by identifier as well.
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
            let connection = WatchConnection(client: connectionClient, device: connectedDevice)
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
            refreshConnectionState()
            await recordConnectedWatch(connectedDevice)
            await restorePendingNotifications()
            await PebbleDiagnostics.shared.record(category: "connection", message: "Watch connected")
            await synchronizeEverything(on: connection)
        } catch let error as PebbleConnectionError {
            lastConnectionError = error
            if !connections.isEmpty {
                watchManagementErrorMessage = error.message
            }
            await PebbleDiagnostics.shared.record(.error, category: "connection", message: error.logDescription)
        } catch {
            lastConnectionError = .protocolNegotiationFailed
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

    func clearBusyOperationState() {
        appFetchTask?.cancel()
        appFetchTask = nil
        isHandlingAppFetch = false
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
        installingApplicationID = nil
        installingApplicationName = nil
        installationProgress = nil
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
        case .transferProgress(let progress):
            if firmwareUpdateTask != nil { firmwareUpdateProgress = progress }
            else { installationProgress = progress }
        case .reconnecting:
            refreshConnectionState()
            needsApplicationSynchronization = true
            // Operations interrupted by the link drop would otherwise leave
            // the app-management UI busy forever.
            clearBusyOperationState()
        case .disconnected(let error):
            connections.removeAll { $0 === connection }
            lastConnectionError = error
            refreshConnectionState()
            needsApplicationSynchronization = true
            clearBusyOperationState()
        case .healthSyncCompleted(let succeeded):
            dataSyncStatusMessage = succeeded ? "Health synchronization completed." : "The watch rejected health synchronization."
        case .healthSamplesReceived(let samples):
            Task { [weak self] in
                guard let self else { return }
                do {
                    self.healthSamples = try await self.healthLibrary.merge(samples)
                    self.dataSyncStatusMessage = "Received \(samples.count) health update(s) from the watch."
                    #if os(iOS)
                    try await self.healthKitBridge.synchronize(self.healthSamples)
                    #endif
                } catch {
                    self.dataSyncStatusMessage = "Watch health data could not be saved."
                }
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
                guard let self, let index = self.timelinePins.firstIndex(where: { $0.id == invocation.itemID }) else { return }
                self.timelinePins.remove(at: index)
                try? await self.timelineLibrary.save(self.timelinePins)
                self.timelineActionStatusMessage = "Timeline action completed."
            }
        }
    }

    /// Brings a watch up to date once it is connected, whether that is the
    /// first connection or a reconnect.
    ///
    /// A watch running its recovery firmware rejects every endpoint this uses
    /// and drops the link a few seconds after being flooded with them, so it is
    /// only offered a firmware install.
    func synchronizeEverything(on connection: WatchConnection) async {
        if connection.device.isRunningRecoveryFirmware {
            watchManagementErrorMessage =
                "This watch started its recovery firmware. Install firmware to finish setting it up."
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
        await requestHealthSync(on: connection)
        await resumePendingFirmwareUpdate(on: connection)
    }

}

public enum ApplicationManagementError: Error, Equatable, Sendable {
    case missingStoredPackage(String)
    case applicationIDMismatch
}
