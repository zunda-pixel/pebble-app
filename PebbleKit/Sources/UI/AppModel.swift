public import API
public import Foundation
import Observation

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
    public private(set) var connectionState: PebbleConnectionState = .idle
    public private(set) var connections: [WatchConnection] = []
    public private(set) var connectingDeviceIDs: Set<String> = []
    public private(set) var discoveredDevices: [DiscoveredPebble] = []
    public private(set) var watchApplications: [PebbleApplication] = []
    public private(set) var watchfaces: [PebbleApplication] = []
    public private(set) var activeWatchfaceID: UUID?
    public private(set) var favoriteWatchfaceIDs: Set<UUID> = []
    public private(set) var isLoadingApplications = false
    public private(set) var isImportingApplication = false
    public private(set) var applicationLibraryErrorMessage: String?
    public private(set) var installingApplicationID: UUID?
    public private(set) var installingApplicationName: String?
    public private(set) var installationProgress: PutBytesTransferProgress?
    public private(set) var applicationManagementOperation: ApplicationManagementOperation?
    public private(set) var applicationManagementStatusMessage: String?
    public private(set) var isHandlingAppFetch = false
    public private(set) var configurationApplication: PebbleApplication?
    public private(set) var configurationURL: URL?
    public private(set) var diagnosticReportURL: URL?
    public private(set) var companionNotificationsEnabled = true
    public private(set) var notificationStatusMessage: String?
    public private(set) var notificationPreferences = NotificationDeliveryPreferences()
    public private(set) var savedWatches: [SavedPebbleWatch] = []
    public private(set) var watchManagementErrorMessage: String?
    public private(set) var timelinePins: [PebbleTimelinePin] = []
    public private(set) var healthSamples: [PebbleHealthSample] = []
    public private(set) var catalogApplications: [PebbleCatalogApplication] = []
    public private(set) var catalogLastUpdated: Date?
    public private(set) var isUpdatingCatalog = false
    public private(set) var installingCatalogApplicationID: UUID?
    public private(set) var firmwareUpdateStatusMessage: String?
    public private(set) var firmwareUpdateJournal: FirmwareUpdateJournal?
    public private(set) var firmwareRequiresConfirmation = false
    public private(set) var firmwareUpdateProgress: PutBytesTransferProgress?
    public private(set) var dataSyncStatusMessage: String?
    public private(set) var timelineActionStatusMessage: String?
    public private(set) var healthExportURL: URL?
    public private(set) var notificationSourceApps: [NotificationSourceApp] = []

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

    private var activeConnections: [WatchConnection] {
        connections.filter(\.isConnected)
    }

    private func connection(for deviceID: String?) -> WatchConnection? {
        guard let deviceID else {
            return activeConnections.first
        }
        return connections.first { $0.device.id == deviceID }
    }

    private let scannerClient: any PebbleClient
    private let clientFactory: @MainActor (String) -> any PebbleClient
    private let applicationLibrary: PebbleApplicationLibrary
    private let watchLibrary: PebbleWatchLibrary
    private let timelineLibrary = TimelinePinLibrary()
    private let healthLibrary = PebbleHealthLibrary()
    private let appCatalog = PebbleAppCatalog()
    private let pendingNotificationLibrary = PendingNotificationLibrary()
    private let notificationPreferenceLibrary = NotificationPreferenceLibrary()
    private let pendingTimelineOperationLibrary = PendingTimelineOperationLibrary()
    private let pendingAppMessageLibrary = PendingAppMessageLibrary()
    private let pendingFirmwareUpdateLibrary = PendingFirmwareUpdateLibrary()
    private var pendingAppMessages: [StoredAppMessage] = []
    private let calendarBridge = CalendarBridge()
    @ObservationIgnored private var calendarChangesTask: Task<Void, Never>?
    #if os(iOS)
    private let healthKitBridge = HealthKitBridge()
    #endif
    private let notificationSourceAppLibrary = NotificationSourceAppLibrary()
    @ObservationIgnored private lazy var musicCoordinator = MusicCoordinator(
        source: makeSystemMusicSource(),
        send: { [weak self] frame in try await self?.broadcast(frame) }
    )
    @ObservationIgnored private lazy var phoneCallCoordinator = PhoneCallCoordinator(
        source: makeSystemCallSource(),
        send: { [weak self] frame in try await self?.broadcast(frame) }
    )
    @ObservationIgnored private var isPerformingScan = false
    @ObservationIgnored private var lastConnectionError: PebbleConnectionError?
    @ObservationIgnored private var firmwareUpdateTask: Task<Void, any Error>?
    @ObservationIgnored private var appFetchTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedApplications = false
    @ObservationIgnored private var pendingImportSnapshots: [UUID: PebbleApplicationLibrarySnapshot] = [:]
    @ObservationIgnored private var needsApplicationSynchronization = false
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var recentNotificationFingerprints: [String: Date] = [:]
    @ObservationIgnored private var pendingNotifications: [PebbleTimelineNotification] = []
    @ObservationIgnored private lazy var companionRuntime = PebbleCompanionRuntime(
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

    private func openConfigurationURL(_ url: URL) {
        guard url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            applicationLibraryErrorMessage = "The application requested an unsafe settings URL."
            Task {
                await PebbleDiagnostics.shared.record(
                    .warning,
                    category: "configuration",
                    message: "Rejected an unsafe configuration URL"
                )
            }
            return
        }
        configurationURL = url
    }

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
        companionNotificationsEnabled = UserDefaults.standard.object(
            forKey: "companionNotificationsEnabled"
        ) as? Bool ?? true
        activeWatchfaceID = UserDefaults.standard.string(forKey: "activeWatchfaceID").flatMap(UUID.init(uuidString:))
        favoriteWatchfaceIDs = Set(
            UserDefaults.standard.stringArray(forKey: "favoriteWatchfaceIDs")?.compactMap(UUID.init(uuidString:)) ?? []
        )
    }

    public var isApplicationManagementBusy: Bool {
        applicationManagementOperation != nil || isHandlingAppFetch
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
        } else if !isPerformingScan, connectingDeviceIDs.isEmpty, connections.isEmpty {
            if savedWatches.contains(where: \.automaticallyConnects) {
                await scan()
            }
        }
    }

    public func scan() async {
        guard !isPerformingScan else { return }
        isPerformingScan = true
        if connections.isEmpty, connectingDeviceIDs.isEmpty {
            connectionState = .scanning
        }
        defer {
            isPerformingScan = false
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
            musicCoordinator.watchConnected()
            await synchronizeNotificationSourceApps(on: connection)
            await synchronizeApplications(on: connection)
            try? await connectionClient.send(AppRunStateCodec.requestFrame())
            await flushPendingNotifications()
            await flushPendingAppMessages()
            await synchronizeTimeline()
            await requestHealthSync(on: connection)
            await resumePendingFirmwareUpdate(on: connection)
        } catch let error as PebbleConnectionError {
            lastConnectionError = error
            if !connections.isEmpty {
                watchManagementErrorMessage = error.message
            }
            await PebbleDiagnostics.shared.record(.error, category: "connection", message: error.message)
        } catch {
            lastConnectionError = .protocolNegotiationFailed
        }
    }

    private func refreshConnectionState() {
        if let connectingID = connectingDeviceIDs.first {
            connectionState = .connecting(deviceID: connectingID)
        } else if let primary = activeConnections.first {
            connectionState = .connected(primary.device)
        } else if let reconnecting = connections.first(where: { $0.phase == .reconnecting }) {
            connectionState = .reconnecting(deviceID: reconnecting.device.id)
        } else if isPerformingScan {
            connectionState = .scanning
        } else if let error = lastConnectionError {
            connectionState = .failed(error)
        } else {
            connectionState = .idle
        }
    }

    public func installFirmware(from url: URL, deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            firmwareUpdateStatusMessage = "Connect the target Pebble before selecting firmware."
            return
        }
        let device = connection.device
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            firmwareUpdateStatusMessage = "Validating firmware…"
            let package = try await Task.detached {
                try PBZFirmwareImporter.load(from: url, for: device.model)
            }.value
            try package.validateIntegrity()
            let journal = FirmwareUpdateJournal(
                deviceID: device.id,
                hardwareRevision: device.model.rawValue,
                previousVersion: device.firmwareVersion,
                targetVersion: package.manifest.firmware.versionTag,
                packageSHA256: package.sha256
            )
            try await pendingFirmwareUpdateLibrary.save(package, journal: journal)
            firmwareUpdateJournal = journal
            if package.manifest.firmware.type == "recovery" {
                firmwareRequiresConfirmation = true
                firmwareUpdateStatusMessage = "Recovery firmware validated. Confirm to continue."
                return
            }
            try await performFirmwareUpdate(package, on: connection)
        } catch {
            firmwareUpdateStatusMessage = "Firmware update stopped safely: \(error.localizedDescription)"
        }
    }

    public func confirmRecoveryFirmwareUpdate() async {
        guard firmwareRequiresConfirmation,
              let package = try? await pendingFirmwareUpdateLibrary.package(),
              let journal = try? await pendingFirmwareUpdateLibrary.journal(),
              let connection = connection(for: journal.deviceID) else { return }
        firmwareRequiresConfirmation = false
        do { try await performFirmwareUpdate(package, on: connection) }
        catch { firmwareUpdateStatusMessage = "Recovery update stopped safely: \(error.localizedDescription)" }
    }

    public func cancelFirmwareUpdate() async {
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        firmwareRequiresConfirmation = false
        try? await pendingFirmwareUpdateLibrary.updatePhase(.cancelled)
        firmwareUpdateJournal = try? await pendingFirmwareUpdateLibrary.journal()
        firmwareUpdateStatusMessage = "Firmware update cancelled; recovery data was retained."
        if let deviceID = firmwareUpdateJournal?.deviceID,
           let connection = connection(for: deviceID) {
            await disconnect(deviceID: connection.device.id)
        }
    }

    public func discardPendingFirmwareUpdate() async {
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        await pendingFirmwareUpdateLibrary.clear()
        firmwareUpdateJournal = nil
        firmwareRequiresConfirmation = false
        firmwareUpdateStatusMessage = "Pending firmware update removed."
    }

    private func performFirmwareUpdate(
        _ package: PBZFirmwarePackage,
        on connection: WatchConnection
    ) async throws {
        try package.validateIntegrity()
        guard let journal = try await pendingFirmwareUpdateLibrary.journal(),
              journal.packageSHA256 == package.sha256,
              journal.deviceID == connection.device.id else {
            throw PBZFirmwareError.unsafeManifest
        }
        try await pendingFirmwareUpdateLibrary.updatePhase(.transferring)
        firmwareUpdateJournal = try await pendingFirmwareUpdateLibrary.journal()
        firmwareUpdateStatusMessage = "Transferring verified firmware…"
        firmwareUpdateProgress = nil
        let client = connection.client
        let task = Task { try await client.installFirmware(package) }
        firmwareUpdateTask = task
        defer { firmwareUpdateTask = nil }
        try await task.value
        try await pendingFirmwareUpdateLibrary.updatePhase(.awaitingRestart)
        firmwareUpdateJournal = try await pendingFirmwareUpdateLibrary.journal()
        firmwareUpdateStatusMessage = "Firmware installed. Waiting for the watch to restart."
        await pendingFirmwareUpdateLibrary.clear()
    }

    public func loadTimeline() async {
        do { timelinePins = try await timelineLibrary.pins() }
        catch { dataSyncStatusMessage = "Timeline could not be loaded." }
    }

    public func addTimelinePin(title: String, date: Date) async {
        let pin = PebbleTimelinePin(
            parentApplicationID: UUID(), timestamp: date, title: title, subtitle: nil, body: nil
        )
        timelinePins.append(pin)
        do {
            try await timelineLibrary.save(timelinePins)
            try await queueTimelineOperation(.upsert(pin))
            if connectedDevice != nil { await synchronizeTimeline() }
            dataSyncStatusMessage = "Timeline pin saved."
        } catch { dataSyncStatusMessage = "Timeline pin queued for the next connection." }
    }

    public func removeTimelinePins(at offsets: IndexSet) async {
        let removed = offsets.compactMap { timelinePins.indices.contains($0) ? timelinePins[$0] : nil }
        timelinePins.remove(atOffsets: offsets)
        try? await timelineLibrary.save(timelinePins)
        for pin in removed { try? await queueTimelineOperation(.delete(pin.id)) }
        if connectedDevice != nil { await synchronizeTimeline() }
    }

    public func synchronizeTimeline() async {
        await loadTimeline()
        guard !activeConnections.isEmpty else { return }
        var operations = (try? await pendingTimelineOperationLibrary.operations()) ?? []
        let queuedUpserts = Set(operations.compactMap { operation -> UUID? in
            if case .upsert(let pin) = operation { return pin.id }
            return nil
        })
        operations += timelinePins.filter { !queuedUpserts.contains($0.id) }.map(PendingTimelineOperation.upsert)
        var remaining: [PendingTimelineOperation] = []
        for (index, operation) in operations.enumerated() {
            do {
                for connection in activeConnections {
                    let client = connection.client
                    switch operation {
                    case .upsert(let pin):
                        try await PebbleRetryPolicy().execute { try await client.upsertTimelinePin(pin) }
                    case .delete(let id):
                        try await PebbleRetryPolicy().execute { try await client.deleteTimelinePin(id: id) }
                    }
                }
            } catch {
                remaining.append(contentsOf: operations[index...])
                break
            }
        }
        try? await pendingTimelineOperationLibrary.save(remaining)
    }

    private func queueTimelineOperation(_ operation: PendingTimelineOperation) async throws {
        var operations = try await pendingTimelineOperationLibrary.operations()
        let id: UUID
        switch operation {
        case .upsert(let pin): id = pin.id
        case .delete(let value): id = value
        }
        operations.removeAll { existing in
            switch existing {
            case .upsert(let pin): pin.id == id
            case .delete(let value): value == id
            }
        }
        operations.append(operation)
        if operations.count > 200 {
            operations.removeFirst(operations.count - 200)
        }
        try await pendingTimelineOperationLibrary.save(operations)
    }

    public func synchronizeCalendar() async {
        do {
            let calendarPins = try await calendarBridge.timelinePins()
            let oldCalendarPins = timelinePins.filter { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.removeAll { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.append(contentsOf: calendarPins)
            try await timelineLibrary.save(timelinePins)
            let newIDs = Set(calendarPins.map(\.id))
            for pin in oldCalendarPins where !newIDs.contains(pin.id) {
                try await queueTimelineOperation(.delete(pin.id))
            }
            for pin in calendarPins { try await queueTimelineOperation(.upsert(pin)) }
            if connectedDevice != nil { await synchronizeTimeline() }
            dataSyncStatusMessage = "Calendar synchronized with Timeline."
        } catch { dataSyncStatusMessage = "Calendar access or synchronization failed." }
    }

    private func observeCalendarChanges() {
        calendarChangesTask?.cancel()
        calendarChangesTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                guard !Task.isCancelled else { return }
                await self?.synchronizeCalendar()
            }
        }
    }

    public func loadHealth() async {
        do { healthSamples = try await healthLibrary.samples() }
        catch { dataSyncStatusMessage = "Health data could not be loaded." }
    }

    public func requestHealthSync() async {
        guard !activeConnections.isEmpty else { return }
        for connection in activeConnections {
            await requestHealthSync(on: connection)
        }
    }

    private func requestHealthSync(on connection: WatchConnection) async {
        do {
            try await connection.client.send(HealthDataLoggingCodec.reportOpenSessionsFrame())
            try await connection.client.send(HealthSyncCodec.requestFrame(since: healthSamples.map(\.date).max()))
            dataSyncStatusMessage = "Health synchronization requested."
        } catch { dataSyncStatusMessage = "Health synchronization will retry after reconnection." }
    }

    #if os(iOS)
    public func synchronizeWithHealthKit() async {
        do {
            try await healthKitBridge.synchronize(healthSamples)
            dataSyncStatusMessage = "Health data synchronized with HealthKit."
        } catch { dataSyncStatusMessage = "HealthKit access or synchronization failed." }
    }

    public func importFromHealthKit() async {
        do {
            healthSamples = try await healthLibrary.merge(try await healthKitBridge.readRecentSamples())
            dataSyncStatusMessage = "HealthKit data imported and deduplicated."
        } catch { dataSyncStatusMessage = "HealthKit data could not be read." }
    }
    #endif

    public func exportHealthData() async {
        do { healthExportURL = try await healthLibrary.export() }
        catch { dataSyncStatusMessage = "Health data could not be exported." }
    }

    public func importHealthData(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            healthSamples = try await healthLibrary.importArchive(from: url)
            dataSyncStatusMessage = "Health archive imported and reconciled."
        } catch {
            dataSyncStatusMessage = "The selected health archive is invalid or unsupported."
        }
    }

    public func deleteHealthData() async {
        try? await healthLibrary.deleteAll()
        healthSamples = []
        healthExportURL = nil
        dataSyncStatusMessage = "Local Pebble health data deleted."
    }

    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot()
            catalogApplications = snapshot?.applications ?? []
            catalogLastUpdated = snapshot?.fetchedAt
        }
        catch { dataSyncStatusMessage = "The app catalog cache could not be loaded." }
    }

    public func updateCatalog(source: String) async {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https" else {
            dataSyncStatusMessage = "Enter a valid HTTPS catalog URL."
            return
        }
        guard !isUpdatingCatalog else { return }
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        do {
            let snapshot = try await appCatalog.update(from: url, model: connectedDevice?.model)
            catalogApplications = snapshot.applications
            catalogLastUpdated = snapshot.fetchedAt
            UserDefaults.standard.set(source, forKey: "appCatalogSource")
            dataSyncStatusMessage = "App catalog updated with \(catalogApplications.count) apps."
        } catch {
            dataSyncStatusMessage = catalogApplications.isEmpty
                ? "The app catalog could not be updated."
                : "Catalog refresh failed; showing the offline cache."
        }
    }

    public func refreshCatalog() async {
        let source = UserDefaults.standard.string(forKey: "appCatalogSource")
            ?? "https://appstore-api.repebble.com/api"
        await updateCatalog(source: source)
    }

    public func catalogInstallationState(for application: PebbleCatalogApplication) -> CatalogInstallationState {
        if !connectedDevices.isEmpty,
           !connectedDevices.contains(where: { application.supports($0.model) }) {
            return .incompatible
        }
        guard let installed = (watchApplications + watchfaces).first(where: { $0.id == application.id }) else {
            return .available
        }
        return application.isNewer(than: installed.versionLabel) ? .updateAvailable : .installed
    }

    public func installCatalogApplication(_ application: PebbleCatalogApplication) async {
        guard application.downloadURL.scheme?.lowercased() == "https" else {
            dataSyncStatusMessage = "The catalog provided an unsafe download URL."
            return
        }
        if catalogInstallationState(for: application) == .incompatible {
            dataSyncStatusMessage = "\(application.name) is not compatible with this watch."
            return
        }
        guard installingCatalogApplicationID == nil else { return }
        installingCatalogApplicationID = application.id
        defer { installingCatalogApplicationID = nil }
        do {
            dataSyncStatusMessage = "Downloading \(application.name)…"
            let packageURL = try await appCatalog.download(application)
            let decoded = try await Task.detached { try PBWPackageImporter.application(from: packageURL) }.value
            guard decoded.id == application.id else { throw AppCatalogError.applicationIDMismatch }
            applicationLibraryErrorMessage = nil
            await importApplication(from: packageURL)
            try? FileManager.default.removeItem(at: packageURL)
            dataSyncStatusMessage = applicationLibraryErrorMessage == nil
                ? "\(application.name) installed."
                : applicationLibraryErrorMessage
        } catch {
            dataSyncStatusMessage = "The catalog package was rejected: \(error.localizedDescription)"
        }
    }

    public func installCatalogUpdates() async {
        let updates = catalogApplications.filter { catalogInstallationState(for: $0) == .updateAvailable }
        guard !updates.isEmpty else {
            dataSyncStatusMessage = "Installed apps are up to date."
            return
        }
        for application in updates {
            await installCatalogApplication(application)
            if applicationLibraryErrorMessage != nil { return }
        }
        dataSyncStatusMessage = "Installed \(updates.count) catalog update(s)."
    }

    public func loadSavedWatches() async {
        do {
            savedWatches = try await watchLibrary.allWatches()
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "Saved watches could not be loaded."
        }
    }

    public func setAutomaticallyConnects(_ enabled: Bool, watchID: String) async {
        do {
            savedWatches = try await watchLibrary.setAutomaticallyConnects(enabled, watchID: watchID)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The automatic connection preference could not be saved."
        }
    }

    public func forgetWatch(id: String) async {
        // Closing the connection also stops any background reconnect loop; a
        // successful reconnect would otherwise re-save the forgotten entry.
        if let connection = connections.first(where: { $0.device.id == id }) {
            await close(connection)
        }
        do {
            savedWatches = try await watchLibrary.remove(watchID: id)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The watch could not be forgotten."
        }
    }

    public func disconnect(deviceID: String) async {
        guard let connection = connections.first(where: { $0.device.id == deviceID }) else {
            return
        }
        await close(connection)
    }

    public func disconnect() async {
        for connection in connections {
            await close(connection)
        }
    }

    private func close(_ connection: WatchConnection) async {
        connections.removeAll { $0 === connection }
        await connection.close()
        clearBusyOperationState()
        needsApplicationSynchronization = true
        lastConnectionError = nil
        refreshConnectionState()
    }

    private func clearBusyOperationState() {
        appFetchTask?.cancel()
        appFetchTask = nil
        isHandlingAppFetch = false
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
        installingApplicationID = nil
        installingApplicationName = nil
        installationProgress = nil
    }

    public func loadApplications() async {
        guard !hasLoadedApplications else {
            return
        }
        hasLoadedApplications = true
        isLoadingApplications = true
        defer { isLoadingApplications = false }
        do {
            updateApplications(try await applicationLibrary.applications())
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = error.localizedDescription
        }
    }

    public func configureApplication(_ application: PebbleApplication) async {
        guard application.isConfigurable else { return }
        do {
            guard let source = try await applicationLibrary.companionJavaScript(
                applicationID: application.id
            ) else { return }
            configurationApplication = application
            configurationURL = nil
            try await companionRuntime.load(source: source, application: application)
            try await companionRuntime.showConfiguration()
            await PebbleDiagnostics.shared.record(
                category: "configuration",
                message: "Requested configuration for \(application.displayName)"
            )
        } catch {
            applicationLibraryErrorMessage = "The application settings could not be opened."
        }
    }

    public func activateWatchface(_ application: PebbleApplication) async {
        guard application.kind == .watchface, !activeConnections.isEmpty else { return }
        do {
            for connection in activeConnections {
                let client = connection.client
                try await PebbleRetryPolicy().execute {
                    try await client.launchApplication(id: application.id)
                }
            }
            activeWatchfaceID = application.id
            UserDefaults.standard.set(application.id.uuidString, forKey: "activeWatchfaceID")
            applicationManagementStatusMessage = "\(application.displayName) is active."
        } catch {
            applicationLibraryErrorMessage = "The watchface could not be activated."
        }
    }

    public func toggleFavoriteWatchface(_ application: PebbleApplication) {
        guard application.kind == .watchface else { return }
        if favoriteWatchfaceIDs.contains(application.id) { favoriteWatchfaceIDs.remove(application.id) }
        else { favoriteWatchfaceIDs.insert(application.id) }
        UserDefaults.standard.set(favoriteWatchfaceIDs.map(\.uuidString), forKey: "favoriteWatchfaceIDs")
    }

    public func closeConfiguration(response: String? = nil) async {
        try? await companionRuntime.closeConfiguration(response: response)
        configurationURL = nil
        configurationApplication = nil
    }

    public func prepareDiagnosticReport() async {
        do {
            diagnosticReportURL = try await PebbleDiagnostics.shared.exportReport(
                device: connectedDevice,
                applications: watchApplications + watchfaces
            )
        } catch {
            applicationLibraryErrorMessage = "The diagnostic report could not be created."
        }
    }

    public func setCompanionNotificationsEnabled(_ enabled: Bool) {
        companionNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "companionNotificationsEnabled")
        notificationStatusMessage = enabled
            ? "Watch app notifications are enabled."
            : "Watch app notifications are disabled."
    }

    public func setNotificationsEnabled(_ enabled: Bool, applicationID: UUID) async {
        if enabled { notificationPreferences.mutedApplicationIDs.remove(applicationID) }
        else { notificationPreferences.mutedApplicationIDs.insert(applicationID) }
        try? await notificationPreferenceLibrary.save(notificationPreferences)
        notificationStatusMessage = enabled ? "Notifications enabled for this app." : "Notifications muted for this app."
    }

    public func setQuietHours(enabled: Bool, start: Int? = nil, end: Int? = nil) async {
        notificationPreferences.quietHoursEnabled = enabled
        if let start { notificationPreferences.quietHoursStart = min(23, max(0, start)) }
        if let end { notificationPreferences.quietHoursEnd = min(23, max(0, end)) }
        try? await notificationPreferenceLibrary.save(notificationPreferences)
    }

    public func sendTestNotification(deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            notificationStatusMessage = "Connect a Pebble before sending a test notification."
            return
        }
        do {
            try await connection.client.sendNotification(PebbleTimelineNotification(
                parentApplicationID: UUID(),
                title: "Pebble Test",
                body: "Notifications are reaching your watch.",
                appName: "Pebble"
            ))
            notificationStatusMessage = "Test notification sent."
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Test notification sent"
            )
        } catch {
            notificationStatusMessage = "The test notification could not be sent."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "notification",
                message: "Test notification delivery failed"
            )
        }
    }

    /// Sends a frame to every connected watch, throwing only when no watch
    /// received it.
    private func broadcast(_ frame: PebbleProtocolFrame) async throws {
        var delivered = false
        for connection in activeConnections {
            do {
                try await connection.client.send(frame)
                delivered = true
            } catch {
                continue
            }
        }
        guard delivered else {
            throw PebbleConnectionError.disconnected
        }
    }

    private func sendCompanionNotification(
        application: PebbleApplication,
        title: String,
        body: String
    ) async throws {
        guard companionNotificationsEnabled else { return }
        guard notificationPreferences.permits(applicationID: application.id, at: Date()) else {
            await PebbleDiagnostics.shared.record(category: "notification", message: "Notification suppressed by delivery preferences")
            return
        }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty || !normalizedBody.isEmpty else { return }
        let now = Date()
        recentNotificationFingerprints = recentNotificationFingerprints.filter {
            now.timeIntervalSince($0.value) < 30
        }
        let fingerprint = "\(application.id.uuidString)|\(normalizedTitle)|\(normalizedBody)"
        guard recentNotificationFingerprints[fingerprint] == nil else { return }
        recentNotificationFingerprints[fingerprint] = now
        do {
            let notification = PebbleTimelineNotification(
                parentApplicationID: application.id,
                title: normalizedTitle,
                body: normalizedBody,
                appName: application.displayName
            )
            guard !activeConnections.isEmpty else {
                pendingNotifications.append(notification)
                if pendingNotifications.count > 20 {
                    pendingNotifications.removeFirst(pendingNotifications.count - 20)
                }
                try? await pendingNotificationLibrary.save(pendingNotifications)
                await PebbleDiagnostics.shared.record(
                    category: "notification",
                    message: "Watch app notification queued until reconnection"
                )
                return
            }
            for connection in activeConnections {
                let client = connection.client
                try await PebbleRetryPolicy().execute {
                    try await client.sendNotification(notification)
                }
            }
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Watch app notification sent"
            )
        } catch {
            recentNotificationFingerprints[fingerprint] = nil
            throw error
        }
    }

    public func removeApplication(id: UUID) async {
        if activeWatchfaceID == id {
            guard let fallback = watchfaces.first(where: { $0.id != id }) else {
                applicationLibraryErrorMessage = "Install and activate another watchface before removing the active one."
                return
            }
            await activateWatchface(fallback)
            guard activeWatchfaceID == fallback.id else { return }
        }
        guard beginApplicationOperation(.removing(id)) else { return }
        defer { finishApplicationOperation(.removing(id)) }
        do {
            let applications = try await applicationLibrary.remove(applicationID: id)
            updateApplications(applications)
            try await synchronizeAllWatches()
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = applicationErrorMessage(error)
        }
    }

    public func importApplication(from url: URL) async {
        guard beginApplicationOperation(.importing) else { return }
        isImportingApplication = true
        defer {
            isImportingApplication = false
            finishApplicationOperation(.importing)
        }
        let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let application = try await Task.detached(priority: .userInitiated) {
                try PBWPackageImporter.application(from: url)
            }.value
            let snapshot = try await applicationLibrary.snapshot(applicationID: application.id)
            let applications = try await applicationLibrary.importPackage(from: url)
            updateApplications(applications)
            if !activeConnections.isEmpty {
                pendingImportSnapshots[application.id] = snapshot
                try await synchronizeAllWatches()
                expirePendingSnapshot(applicationID: application.id)
            }
            hasLoadedApplications = true
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = applicationErrorMessage(error)
        }
    }

    public func reorderApplications(
        kind: PebbleApplicationKind,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async {
        guard beginApplicationOperation(.reordering) else { return }
        defer { finishApplicationOperation(.reordering) }
        var selectedApplications = kind == .watchapp ? watchApplications : watchfaces
        guard move(&selectedApplications, fromOffsets: fromOffsets, toOffset: toOffset) else {
            return
        }
        let orderedApplications = kind == .watchapp
            ? selectedApplications + watchfaces
            : watchApplications + selectedApplications

        do {
            let previousApplications = try await applicationLibrary.applications()
            let applications = try await applicationLibrary.reorder(
                applicationIDs: orderedApplications.map(\.id)
            )
            updateApplications(applications)
            do {
                try await synchronizeAllWatches()
            } catch {
                let restored = try await applicationLibrary.reorder(
                    applicationIDs: previousApplications.map(\.id)
                )
                updateApplications(restored)
                try? await synchronizeAllWatches()
                throw error
            }
            applicationLibraryErrorMessage = nil
        } catch {
            applicationLibraryErrorMessage = applicationErrorMessage(error)
        }
    }

    private func move(
        _ applications: inout [PebbleApplication],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> Bool {
        guard !fromOffsets.isEmpty,
              fromOffsets.allSatisfy(applications.indices.contains),
              (0...applications.count).contains(toOffset) else {
            return false
        }
        let movingApplications = fromOffsets.map { applications[$0] }
        applications = applications.enumerated().compactMap { index, application in
            fromOffsets.contains(index) ? nil : application
        }
        let removedBeforeDestination = fromOffsets.count { $0 < toOffset }
        let insertionIndex = toOffset - removedBeforeDestination
        applications.insert(contentsOf: movingApplications, at: insertionIndex)
        return true
    }

    private func beginApplicationOperation(_ operation: ApplicationManagementOperation) -> Bool {
        guard applicationManagementOperation == nil, !isHandlingAppFetch else {
            applicationLibraryErrorMessage = "Another application operation is already in progress."
            return false
        }
        applicationManagementOperation = operation
        applicationManagementStatusMessage = statusMessage(for: operation)
        return true
    }

    private func finishApplicationOperation(_ operation: ApplicationManagementOperation) {
        guard applicationManagementOperation == operation else { return }
        let completedOperation = applicationManagementOperation
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
        if needsApplicationSynchronization,
           completedOperation != .synchronizing,
           !activeConnections.isEmpty {
            needsApplicationSynchronization = false
            Task { [weak self] in
                guard let self else { return }
                for connection in self.activeConnections {
                    await self.synchronizeApplications(on: connection)
                }
            }
        }
    }

    /// Reconciles the local application library with every connected watch.
    /// The library is the source of truth; each watch gets the compatible
    /// subset registered in order.
    private func synchronizeAllWatches() async throws {
        for connection in activeConnections {
            try await performApplicationSynchronization(on: connection)
        }
    }

    private func synchronizeApplications(on connection: WatchConnection) async {
        guard connection.isConnected else { return }
        guard beginApplicationOperation(.synchronizing) else {
            needsApplicationSynchronization = true
            return
        }
        needsApplicationSynchronization = false
        defer { finishApplicationOperation(.synchronizing) }

        do {
            try await performApplicationSynchronization(on: connection)
            applicationLibraryErrorMessage = nil
        } catch {
            needsApplicationSynchronization = true
            applicationLibraryErrorMessage = applicationErrorMessage(error)
        }
    }

    private func performApplicationSynchronization(on connection: WatchConnection) async throws {
        let device = connection.device
        let applications = try await applicationLibrary.applications()
        let synchronizedIDs = try await applicationLibrary.synchronizedApplicationIDs(deviceID: device.id)
        let compatibleApplications = compatibleApplications(applications, with: device.model)
        let localIDs = Set(compatibleApplications.map(\.id))
        for applicationID in synchronizedIDs where !localIDs.contains(applicationID) {
            try await connection.client.unregisterApplication(applicationID: applicationID)
        }
        for application in compatibleApplications {
            guard let packageURL = await applicationLibrary.storedPackageURL(applicationID: application.id) else {
                throw ApplicationManagementError.missingStoredPackage(application.displayName)
            }
            let package = try await loadPackage(from: packageURL, for: device.model)
            try await connection.client.registerApplication(package.appMetadata)
        }
        try await connection.client.reorderApplications(compatibleApplications.map(\.id))
        try await recordSynchronizedApplications(applications, device: device)
        updateApplications(applications)
    }

    private func recordSynchronizedApplications(
        _ applications: [PebbleApplication],
        device: PebbleDevice
    ) async throws {
        try await applicationLibrary.setSynchronizedApplicationIDs(
            compatibleApplications(applications, with: device.model).map(\.id),
            deviceID: device.id
        )
    }

    private func compatibleApplications(
        _ applications: [PebbleApplication],
        with model: PebbleWatchModel
    ) -> [PebbleApplication] {
        applications.filter { $0.bestVariant(for: model) != nil }
    }

    private func loadPackage(from url: URL, for model: PebbleWatchModel) async throws -> PBWPackage {
        try await Task.detached(priority: .userInitiated) {
            try PBWPackageImporter.load(from: url, for: model)
        }.value
    }

    private func restoreWatchRegistration(
        snapshot: PebbleApplicationLibrarySnapshot,
        applicationID: UUID,
        on connection: WatchConnection
    ) async throws {
        guard snapshot.packageData != nil,
              let packageURL = await applicationLibrary.storedPackageURL(applicationID: applicationID) else {
            try await connection.client.unregisterApplication(applicationID: applicationID)
            return
        }
        let package = try await loadPackage(from: packageURL, for: connection.device.model)
        try await connection.client.registerApplication(package.appMetadata)
    }

    private func expirePendingSnapshot(applicationID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.pendingImportSnapshots[applicationID] = nil
        }
    }

    private func statusMessage(for operation: ApplicationManagementOperation) -> String {
        switch operation {
        case .importing:
            "Preparing application…"
        case .installing:
            "Installing application…"
        case .removing:
            "Removing application…"
        case .reordering:
            "Updating application order…"
        case .synchronizing:
            "Synchronizing applications…"
        }
    }

    private func applicationErrorMessage(_ error: any Error) -> String {
        switch error {
        case let error as PebbleConnectionError:
            error.message
        case BlobDBClientError.operationAlreadyInProgress:
            "The watch is already processing another application change. Please try again."
        case BlobDBClientError.rejected(.databaseFull):
            "The watch does not have enough space for this application."
        case BlobDBClientError.rejected(.locked), BlobDBClientError.rejected(.tryLater):
            "The watch is busy. Please wait and try again."
        case is BlobDBClientError:
            "The watch rejected the application change."
        case AppReorderClientError.operationAlreadyInProgress:
            "The watch is already updating the application order."
        case AppReorderClientError.rejected(.retry):
            "The watch is busy. Please try changing the application order again."
        case is AppReorderClientError:
            "The watch rejected the application order. The previous order was restored."
        case PutBytesTransferError.negativeAcknowledgement:
            "The watch rejected the application data. The previous version was restored."
        case is PutBytesTransferError, is PutBytesCodecError:
            "The application transfer was interrupted. The previous version was restored."
        case PBWManifestError.noCompatibleVariant:
            "This application does not support the connected Pebble model."
        case PBWPackageImportError.applicationIDMismatch:
            "The PBW package contains mismatched application identifiers."
        case PBWPackageImportError.missingExecutable:
            "The PBW package does not contain an application executable."
        case is PBWPackageImportError, is PBWManifestError, is PBWBinaryHeaderError, is PBWApplicationError:
            "The selected PBW package is invalid or incomplete."
        case ApplicationManagementError.missingStoredPackage(let name):
            "The stored package for \(name) is missing. Import it again."
        case ApplicationManagementError.applicationIDMismatch:
            "The watch requested an application that does not match the stored PBW package."
        default:
            "The application operation could not be completed. \(error.localizedDescription)"
        }
    }

    private func updateApplications(_ applications: [PebbleApplication]) {
        watchApplications = applications.filter { $0.kind == .watchapp }
        watchfaces = applications.filter { $0.kind == .watchface }
    }

    private func handleEvent(_ event: PebbleClientEvent, from connection: WatchConnection) {
        switch event {
        case .deviceUpdated(let device):
            let needsResync = connection.consumePostReconnectSync()
            refreshConnectionState()
            Task { [weak self] in
                await self?.recordConnectedWatch(device)
            }
            guard needsResync else { return }
            musicCoordinator.watchConnected()
            Task { [weak self] in
                guard let self else { return }
                await self.synchronizeNotificationSourceApps(on: connection)
                await self.synchronizeApplications(on: connection)
                await self.flushPendingNotifications()
                await self.flushPendingAppMessages()
                await self.synchronizeTimeline()
                await self.requestHealthSync(on: connection)
                await self.resumePendingFirmwareUpdate(on: connection)
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
                    UserDefaults.standard.set(id.uuidString, forKey: "activeWatchfaceID")
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

    private func handleCompanionFrame(
        _ frame: PebbleProtocolFrame,
        from connection: WatchConnection
    ) async {
        switch frame.endpoint {
        case MusicControlCodec.endpoint:
            musicCoordinator.handleFrame(frame)
        case PhoneControlCodec.endpoint:
            phoneCallCoordinator.handleFrame(frame)
        case VoiceControlCodec.endpoint:
            await connection.voiceCoordinator.handleVoiceFrame(frame)
        case AudioStreamCodec.endpoint:
            await connection.voiceCoordinator.handleAudioFrame(frame)
        case BlobDB2Codec.endpoint:
            await handleWatchDatabaseWrite(frame, on: connection)
        default:
            return
        }
    }

    private func handleWatchDatabaseWrite(
        _ frame: PebbleProtocolFrame,
        on connection: WatchConnection
    ) async {
        guard let message = try? BlobDB2Codec.decode(frame) else {
            return
        }
        switch message {
        case .write(let write), .writeBack(let write):
            var succeeded = false
            if write.databaseID == NotificationAppsCodec.databaseID,
               let app = try? NotificationAppsCodec.decodeRecord(
                   key: write.key,
                   value: write.value,
                   timestamp: write.timestamp
               ),
               let apps = try? await notificationSourceAppLibrary.merge(app) {
                notificationSourceApps = apps
                // The watch already holds this record; skip echoing it back.
                connection.synchronizedNotificationAppRecords[app.bundleID] = NotificationAppsCodec.value(
                    for: apps.first { $0.bundleID == app.bundleID } ?? app
                )
                succeeded = true
                // Other connected watches still need the updated record.
                for other in activeConnections where other !== connection {
                    await synchronizeNotificationSourceApps(on: other)
                }
            }
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: succeeded))
        case .syncDone:
            try? await connection.client.send(BlobDB2Codec.responseFrame(to: message, succeeded: true))
        }
    }

    private func synchronizeNotificationSourceApps(on connection: WatchConnection) async {
        for app in notificationSourceApps {
            let value = NotificationAppsCodec.value(for: app)
            guard connection.synchronizedNotificationAppRecords[app.bundleID] != value else {
                continue
            }
            connection.blobDBTokenCounter &+= 1
            do {
                try await connection.client.send(
                    NotificationAppsCodec.insertFrame(app: app, token: connection.blobDBTokenCounter)
                )
                connection.synchronizedNotificationAppRecords[app.bundleID] = value
            } catch {
                return
            }
        }
    }

    public func setNotificationSourceAppMute(bundleID: String, muteState: NotificationAppMuteState) async {
        guard var app = notificationSourceApps.first(where: { $0.bundleID == bundleID }) else {
            return
        }
        app.muteState = muteState
        app.muteExpiration = nil
        app.stateUpdated = .now
        if let apps = try? await notificationSourceAppLibrary.merge(app) {
            notificationSourceApps = apps
        }
        for connection in activeConnections {
            await synchronizeNotificationSourceApps(on: connection)
        }
    }

    public func removeNotificationSourceApps(at offsets: IndexSet) async {
        let removed = offsets.compactMap { notificationSourceApps.indices.contains($0) ? notificationSourceApps[$0] : nil }
        guard !removed.isEmpty else { return }
        var apps = notificationSourceApps
        apps.remove(atOffsets: offsets)
        try? await notificationSourceAppLibrary.save(apps)
        notificationSourceApps = (try? await notificationSourceAppLibrary.apps()) ?? apps
        for app in removed {
            for connection in activeConnections {
                connection.blobDBTokenCounter &+= 1
                connection.synchronizedNotificationAppRecords[app.bundleID] = nil
                try? await connection.client.send(
                    NotificationAppsCodec.deleteFrame(bundleID: app.bundleID, token: connection.blobDBTokenCounter)
                )
            }
        }
    }

    private func recordConnectedWatch(_ device: PebbleDevice) async {
        do {
            savedWatches = try await watchLibrary.record(device)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The watch connection history could not be saved."
        }
    }

    private func handleAppMessage(_ message: AppMessageData, from connection: WatchConnection) async {
        do {
            guard let application = (watchApplications + watchfaces).first(where: {
                $0.id == message.applicationID
            }), let source = try await applicationLibrary.companionJavaScript(
                applicationID: application.id
            ) else {
                try await connection.client.respondToAppMessage(
                    transactionID: message.transactionID,
                    acknowledged: false
                )
                return
            }
            try await companionRuntime.load(source: source, application: application)
            try await companionRuntime.deliver(message)
            try await connection.client.respondToAppMessage(
                transactionID: message.transactionID,
                acknowledged: true
            )
        } catch {
            try? await connection.client.respondToAppMessage(
                transactionID: message.transactionID,
                acknowledged: false
            )
            await PebbleDiagnostics.shared.record(
                .error,
                category: "appmessage",
                message: "Incoming AppMessage delivery failed"
            )
        }
    }

    private func flushPendingNotifications() async {
        guard !activeConnections.isEmpty, !pendingNotifications.isEmpty else { return }
        var remaining: [PebbleTimelineNotification] = []
        for (index, notification) in pendingNotifications.enumerated() {
            do {
                for connection in activeConnections {
                    let client = connection.client
                    try await PebbleRetryPolicy().execute {
                        try await client.sendNotification(notification)
                    }
                }
            } catch {
                remaining.append(contentsOf: pendingNotifications[index...])
                break
            }
        }
        pendingNotifications = remaining
        try? await pendingNotificationLibrary.save(remaining)
        if remaining.isEmpty {
            await PebbleDiagnostics.shared.record(
                category: "notification",
                message: "Queued watch app notifications delivered"
            )
        }
    }

    private func restorePendingNotifications() async {
        if let saved = try? await pendingNotificationLibrary.notifications() {
            pendingNotifications = saved
        }
    }

    private func sendOrQueueAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard let connection = activeConnections.first else {
            pendingAppMessages.append(StoredAppMessage(applicationID: applicationID, tuples: tuples))
            if pendingAppMessages.count > 50 { pendingAppMessages.removeFirst(pendingAppMessages.count - 50) }
            try await pendingAppMessageLibrary.save(pendingAppMessages)
            return
        }
        try await connection.client.sendAppMessage(applicationID: applicationID, tuples: tuples)
    }

    private func flushPendingAppMessages() async {
        guard let connection = activeConnections.first else { return }
        while let message = pendingAppMessages.first {
            do {
                try await connection.client.sendAppMessage(
                    applicationID: message.applicationID,
                    tuples: message.tuples
                )
                pendingAppMessages.removeFirst()
            } catch { break }
        }
        try? await pendingAppMessageLibrary.save(pendingAppMessages)
    }

    private func resumePendingFirmwareUpdate(on connection: WatchConnection) async {
        let device = connection.device
        guard UserDefaults.standard.object(forKey: "autoResumeFirmwareUpdate") as? Bool ?? true,
              let package = try? await pendingFirmwareUpdateLibrary.package(),
              let journal = try? await pendingFirmwareUpdateLibrary.journal(),
              journal.deviceID == device.id,
              journal.hardwareRevision == device.model.rawValue,
              journal.packageSHA256 == package.sha256,
              journal.phase != .cancelled else { return }
        firmwareUpdateJournal = journal
        if package.manifest.firmware.type == "recovery" {
            firmwareRequiresConfirmation = true
            firmwareUpdateStatusMessage = "Interrupted recovery update requires confirmation."
            return
        }
        do {
            firmwareUpdateStatusMessage = "Resuming interrupted firmware update…"
            try await performFirmwareUpdate(package, on: connection)
            firmwareUpdateStatusMessage = "Firmware update resumed successfully."
        } catch {
            firmwareUpdateStatusMessage = "Firmware update remains queued for reconnection."
        }
    }

    private func beginHandlingAppFetchRequest(
        _ request: AppFetchRequest,
        from connection: WatchConnection
    ) {
        let operationAllowsFetch = applicationManagementOperation == nil
            || applicationManagementOperation == .synchronizing
            || pendingImportSnapshots[request.applicationID] != nil
        guard appFetchTask == nil, operationAllowsFetch else {
            Task { try? await connection.client.respondToAppFetch(with: .busy) }
            return
        }
        let ownsOperation = applicationManagementOperation == nil
            || pendingImportSnapshots[request.applicationID] != nil
        if ownsOperation {
            applicationManagementOperation = .installing(request.applicationID)
            applicationManagementStatusMessage = statusMessage(for: .installing(request.applicationID))
        }
        isHandlingAppFetch = true
        appFetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.handleAppFetchRequest(request, from: connection)
            self.appFetchTask = nil
            self.isHandlingAppFetch = false
            if ownsOperation {
                self.finishApplicationOperation(.installing(request.applicationID))
            }
        }
    }

    private func handleAppFetchRequest(
        _ request: AppFetchRequest,
        from connection: WatchConnection
    ) async {
        guard let packageURL = await applicationLibrary.storedPackageURL(
            applicationID: request.applicationID
        ) else {
            try? await connection.client.respondToAppFetch(with: .noData)
            return
        }

        installingApplicationID = request.applicationID
        installingApplicationName = (watchApplications + watchfaces)
            .first { $0.id == request.applicationID }?
            .displayName
        installationProgress = PutBytesTransferProgress(bytesSent: 0, totalBytes: 0)
        defer {
            installingApplicationID = nil
            installingApplicationName = nil
            installationProgress = nil
        }

        do {
            let model = connection.device.model
            let package = try await Task.detached(priority: .userInitiated) {
                try PBWPackageImporter.load(from: packageURL, for: model)
            }.value
            guard package.application.id == request.applicationID else {
                try await connection.client.respondToAppFetch(with: .invalidApplicationID)
                throw ApplicationManagementError.applicationIDMismatch
            }

            try await connection.client.respondToAppFetch(with: .start)
            for object in package.objects {
                try await connection.client.installApplicationObject(
                    [UInt8](object.data),
                    objectType: object.installationObject.objectType,
                    appBankID: request.appBankID
                )
            }
            try await connection.client.registerApplication(package.appMetadata)
            let applications = try await applicationLibrary.applications()
            try await connection.client.reorderApplications(
                compatibleApplications(applications, with: model).map(\.id)
            )
            try await recordSynchronizedApplications(applications, device: connection.device)
            pendingImportSnapshots[request.applicationID] = nil
            applicationLibraryErrorMessage = nil
        } catch {
            if let snapshot = pendingImportSnapshots.removeValue(forKey: request.applicationID) {
                if let restored = try? await applicationLibrary.restore(snapshot) {
                    updateApplications(restored)
                }
                try? await restoreWatchRegistration(
                    snapshot: snapshot,
                    applicationID: request.applicationID,
                    on: connection
                )
            }
            applicationLibraryErrorMessage = applicationErrorMessage(error)
            try? await connection.client.respondToAppFetch(with: .noData)
        }
    }
}

public enum ApplicationManagementError: Error, Equatable, Sendable {
    case missingStoredPackage(String)
    case applicationIDMismatch
}
