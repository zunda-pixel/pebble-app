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

@MainActor
@Observable
public final class AppModel {
    public private(set) var connectionState: PebbleConnectionState = .idle
    public private(set) var discoveredDevices: [DiscoveredPebble] = []
    public private(set) var watchApplications: [PebbleApplication] = []
    public private(set) var watchfaces: [PebbleApplication] = []
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
    public private(set) var savedWatches: [SavedPebbleWatch] = []
    public private(set) var watchManagementErrorMessage: String?
    public private(set) var timelinePins: [PebbleTimelinePin] = []
    public private(set) var healthSamples: [PebbleHealthSample] = []
    public private(set) var catalogApplications: [PebbleCatalogApplication] = []
    public private(set) var firmwareUpdateStatusMessage: String?
    public private(set) var dataSyncStatusMessage: String?
    public private(set) var healthExportURL: URL?

    private let client: any PebbleClient
    private let applicationLibrary: PebbleApplicationLibrary
    private let watchLibrary: PebbleWatchLibrary
    private let timelineLibrary = TimelinePinLibrary()
    private let healthLibrary = PebbleHealthLibrary()
    private let appCatalog = PebbleAppCatalog()
    private let pendingNotificationLibrary = PendingNotificationLibrary()
    private let pendingAppMessageLibrary = PendingAppMessageLibrary()
    private let pendingFirmwareUpdateLibrary = PendingFirmwareUpdateLibrary()
    private var pendingAppMessages: [StoredAppMessage] = []
    private let calendarBridge = CalendarBridge()
    @ObservationIgnored private var calendarChangesTask: Task<Void, Never>?
    #if os(iOS)
    private let healthKitBridge = HealthKitBridge()
    #endif
    @ObservationIgnored private var connectionEventsTask: Task<Void, Never>?
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
        guard ["https", "http"].contains(url.scheme?.lowercased()),
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
        watchLibrary: PebbleWatchLibrary = PebbleWatchLibrary()
    ) {
        self.client = client
        self.applicationLibrary = applicationLibrary
        self.watchLibrary = watchLibrary
        companionNotificationsEnabled = UserDefaults.standard.object(
            forKey: "companionNotificationsEnabled"
        ) as? Bool ?? true
    }

    public var connectedDevice: PebbleDevice? {
        guard case .connected(let device) = connectionState else {
            return nil
        }
        return device
    }

    public var isApplicationManagementBusy: Bool {
        applicationManagementOperation != nil || isHandlingAppFetch
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await loadSavedWatches()
        await restorePendingNotifications()
        pendingAppMessages = (try? await pendingAppMessageLibrary.messages()) ?? []
        await loadTimeline()
        await loadHealth()
        await loadCatalog()
        if savedWatches.contains(where: \.automaticallyConnects) {
            await scan()
        }
        observeCalendarChanges()
    }

    public func scan() async {
        connectionState = .scanning

        do {
            discoveredDevices = try await client.scan()
            connectionState = .idle
            await loadSavedWatches()
            if let device = discoveredDevices.first(where: { discovered in
                savedWatches.contains {
                    $0.id == discovered.id && $0.automaticallyConnects
                }
            }) {
                await connect(to: device)
            }
        } catch let error as PebbleConnectionError {
            connectionState = .failed(error)
        } catch {
            connectionState = .failed(.bluetoothUnavailable)
        }
    }

    public func connect(to device: DiscoveredPebble) async {
        connectionState = .connecting(deviceID: device.id)

        do {
            let connectedDevice = try await client.connect(to: device)
            connectionState = .connected(connectedDevice)
            await recordConnectedWatch(connectedDevice)
            await restorePendingNotifications()
            await PebbleDiagnostics.shared.record(category: "connection", message: "Watch connected")
            observeConnectionEvents()
            await synchronizeApplications(with: connectedDevice)
            await flushPendingNotifications()
            await flushPendingAppMessages()
            await synchronizeTimeline()
            await requestHealthSync()
            await resumePendingFirmwareUpdate()
        } catch let error as PebbleConnectionError {
            connectionState = .failed(error)
            await PebbleDiagnostics.shared.record(.error, category: "connection", message: error.message)
        } catch {
            connectionState = .failed(.protocolNegotiationFailed)
        }
    }

    public func installFirmware(from url: URL) async {
        guard let device = connectedDevice else {
            firmwareUpdateStatusMessage = "Connect the target Pebble before selecting firmware."
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            firmwareUpdateStatusMessage = "Validating firmware…"
            let package = try await Task.detached {
                try PBZFirmwareImporter.load(from: url, for: device.model)
            }.value
            try await pendingFirmwareUpdateLibrary.save(package)
            firmwareUpdateStatusMessage = "Transferring and installing firmware…"
            try await client.installFirmware(package)
            await pendingFirmwareUpdateLibrary.clear()
            firmwareUpdateStatusMessage = "Firmware installed. Waiting for the watch to restart."
        } catch {
            firmwareUpdateStatusMessage = "Firmware update stopped safely: \(error.localizedDescription)"
        }
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
            if connectedDevice != nil { try await client.upsertTimelinePin(pin) }
            dataSyncStatusMessage = "Timeline pin saved."
        } catch { dataSyncStatusMessage = "Timeline pin queued for the next connection." }
    }

    public func removeTimelinePins(at offsets: IndexSet) async {
        let removed = offsets.compactMap { timelinePins.indices.contains($0) ? timelinePins[$0] : nil }
        timelinePins.remove(atOffsets: offsets)
        try? await timelineLibrary.save(timelinePins)
        guard connectedDevice != nil else { return }
        for pin in removed { try? await client.deleteTimelinePin(id: pin.id) }
    }

    public func synchronizeTimeline() async {
        await loadTimeline()
        guard connectedDevice != nil else { return }
        for pin in timelinePins { try? await client.upsertTimelinePin(pin) }
    }

    public func synchronizeCalendar() async {
        do {
            let calendarPins = try await calendarBridge.timelinePins()
            let oldCalendarPins = timelinePins.filter { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.removeAll { $0.parentApplicationID == CalendarBridge.calendarApplicationID }
            timelinePins.append(contentsOf: calendarPins)
            try await timelineLibrary.save(timelinePins)
            if connectedDevice != nil {
                let newIDs = Set(calendarPins.map(\.id))
                for pin in oldCalendarPins where !newIDs.contains(pin.id) { try? await client.deleteTimelinePin(id: pin.id) }
                for pin in calendarPins { try await client.upsertTimelinePin(pin) }
            }
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
        guard connectedDevice != nil else { return }
        do {
            try await client.send(HealthDataLoggingCodec.reportOpenSessionsFrame())
            try await client.send(HealthSyncCodec.requestFrame(since: healthSamples.map(\.date).max()))
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
        do { catalogApplications = try await appCatalog.cachedApplications() }
        catch { dataSyncStatusMessage = "The app catalog cache could not be loaded." }
    }

    public func updateCatalog(source: String) async {
        guard let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased()) else {
            dataSyncStatusMessage = "Enter a valid HTTPS catalog URL."
            return
        }
        do {
            catalogApplications = try await appCatalog.update(from: url)
            UserDefaults.standard.set(source, forKey: "appCatalogSource")
            dataSyncStatusMessage = "App catalog updated."
        } catch { dataSyncStatusMessage = "The app catalog could not be updated." }
    }

    public func installCatalogApplication(_ application: PebbleCatalogApplication) async {
        guard ["https", "http"].contains(application.downloadURL.scheme?.lowercased()) else {
            dataSyncStatusMessage = "The catalog provided an unsafe download URL."
            return
        }
        do {
            dataSyncStatusMessage = "Downloading \(application.name)…"
            let (temporaryURL, response) = try await URLSession.shared.download(from: application.downloadURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AppCatalogError.invalidResponse
            }
            let packageURL = FileManager.default.temporaryDirectory
                .appending(path: "\(application.id.uuidString).pbw")
            try? FileManager.default.removeItem(at: packageURL)
            try FileManager.default.moveItem(at: temporaryURL, to: packageURL)
            await importApplication(from: packageURL)
            try? FileManager.default.removeItem(at: packageURL)
            dataSyncStatusMessage = applicationLibraryErrorMessage == nil
                ? "\(application.name) installed."
                : applicationLibraryErrorMessage
        } catch { dataSyncStatusMessage = "The catalog app could not be downloaded." }
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
        if connectedDevice?.id == id {
            await disconnect()
        }
        do {
            savedWatches = try await watchLibrary.remove(watchID: id)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The watch could not be forgotten."
        }
    }

    public func disconnect() async {
        guard let device = connectedDevice else {
            return
        }

        await client.disconnect(from: device)
        connectionEventsTask?.cancel()
        connectionEventsTask = nil
        appFetchTask?.cancel()
        appFetchTask = nil
        isHandlingAppFetch = false
        applicationManagementOperation = nil
        applicationManagementStatusMessage = nil
        needsApplicationSynchronization = true
        connectionState = .idle
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

    public func sendTestNotification() async {
        guard connectedDevice != nil else {
            notificationStatusMessage = "Connect a Pebble before sending a test notification."
            return
        }
        do {
            try await client.sendNotification(PebbleTimelineNotification(
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

    private func sendCompanionNotification(
        application: PebbleApplication,
        title: String,
        body: String
    ) async throws {
        guard companionNotificationsEnabled else { return }
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
            guard connectedDevice != nil else {
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
            try await client.sendNotification(notification)
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
        guard beginApplicationOperation(.removing(id)) else { return }
        defer { finishApplicationOperation(.removing(id)) }
        do {
            let snapshot = try await applicationLibrary.snapshot(applicationID: id)
            var previousMetadata: PebbleAppMetadata?
            if let connectedDevice,
               let packageURL = await applicationLibrary.storedPackageURL(applicationID: id) {
                previousMetadata = try await loadPackage(from: packageURL, for: connectedDevice.model).appMetadata
                try await client.unregisterApplication(applicationID: id)
            }
            do {
                let applications = try await applicationLibrary.remove(applicationID: id)
                updateApplications(applications)
                if let connectedDevice {
                    try await recordSynchronizedApplications(applications, device: connectedDevice)
                }
            } catch {
                if let previousMetadata {
                    try? await client.registerApplication(previousMetadata)
                }
                _ = try? await applicationLibrary.restore(snapshot)
                throw error
            }
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
            let connectedPackage: PBWPackage?
            if let connectedDevice {
                connectedPackage = try await loadPackage(from: url, for: connectedDevice.model)
            } else {
                connectedPackage = nil
            }

            let applications = try await applicationLibrary.importPackage(from: url)
            updateApplications(applications)
            if let connectedDevice, let connectedPackage {
                pendingImportSnapshots[application.id] = snapshot
                do {
                    try await client.registerApplication(connectedPackage.appMetadata)
                    let compatibleApplications = compatibleApplications(applications, with: connectedDevice.model)
                    try await client.reorderApplications(compatibleApplications.map(\.id))
                    try await recordSynchronizedApplications(applications, device: connectedDevice)
                    expirePendingSnapshot(applicationID: application.id)
                } catch {
                    pendingImportSnapshots[application.id] = nil
                    updateApplications(try await applicationLibrary.restore(snapshot))
                    try? await restoreWatchRegistration(
                        snapshot: snapshot,
                        applicationID: application.id,
                        model: connectedDevice.model
                    )
                    throw error
                }
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
            if let connectedDevice {
                do {
                    let compatibleApplications = compatibleApplications(applications, with: connectedDevice.model)
                    try await client.reorderApplications(compatibleApplications.map(\.id))
                    try await recordSynchronizedApplications(applications, device: connectedDevice)
                } catch {
                    let restored = try await applicationLibrary.reorder(
                        applicationIDs: previousApplications.map(\.id)
                    )
                    updateApplications(restored)
                    try? await client.reorderApplications(
                        compatibleApplications(restored, with: connectedDevice.model).map(\.id)
                    )
                    throw error
                }
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
           let connectedDevice {
            needsApplicationSynchronization = false
            Task { [weak self] in
                await self?.synchronizeApplications(with: connectedDevice)
            }
        }
    }

    private func synchronizeApplications(with device: PebbleDevice) async {
        guard beginApplicationOperation(.synchronizing) else {
            needsApplicationSynchronization = true
            return
        }
        needsApplicationSynchronization = false
        defer { finishApplicationOperation(.synchronizing) }

        do {
            let applications = try await applicationLibrary.applications()
            let synchronizedIDs = try await applicationLibrary.synchronizedApplicationIDs(deviceID: device.id)
            let compatibleApplications = compatibleApplications(applications, with: device.model)
            let localIDs = Set(compatibleApplications.map(\.id))
            for applicationID in synchronizedIDs where !localIDs.contains(applicationID) {
                try await client.unregisterApplication(applicationID: applicationID)
            }
            for application in compatibleApplications {
                guard let packageURL = await applicationLibrary.storedPackageURL(applicationID: application.id) else {
                    throw ApplicationManagementError.missingStoredPackage(application.displayName)
                }
                let package = try await loadPackage(from: packageURL, for: device.model)
                try await client.registerApplication(package.appMetadata)
            }
            try await client.reorderApplications(compatibleApplications.map(\.id))
            try await recordSynchronizedApplications(applications, device: device)
            updateApplications(applications)
            applicationLibraryErrorMessage = nil
        } catch {
            needsApplicationSynchronization = true
            applicationLibraryErrorMessage = applicationErrorMessage(error)
        }
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
        model: PebbleWatchModel
    ) async throws {
        guard snapshot.packageData != nil,
              let packageURL = await applicationLibrary.storedPackageURL(applicationID: applicationID) else {
            try await client.unregisterApplication(applicationID: applicationID)
            return
        }
        try await client.registerApplication(try await loadPackage(from: packageURL, for: model).appMetadata)
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

    private func observeConnectionEvents() {
        connectionEventsTask?.cancel()
        connectionEventsTask = Task { [weak self, client] in
            for await event in client.events() {
                guard !Task.isCancelled else {
                    return
                }
                switch event {
                case .deviceUpdated(let device):
                    self?.connectionState = .connected(device)
                    Task { [weak self] in
                        await self?.recordConnectedWatch(device)
                        await self?.synchronizeApplications(with: device)
                        await self?.flushPendingNotifications()
                        await self?.flushPendingAppMessages()
                        await self?.synchronizeTimeline()
                        await self?.requestHealthSync()
                        await self?.resumePendingFirmwareUpdate()
                    }
                case .appFetchRequested(let request):
                    self?.beginHandlingAppFetchRequest(request)
                case .appMessageReceived(let message):
                    Task { [weak self] in await self?.handleAppMessage(message) }
                case .transferProgress(let progress):
                    self?.installationProgress = progress
                case .reconnecting(let deviceID):
                    self?.connectionState = .reconnecting(deviceID: deviceID)
                    self?.needsApplicationSynchronization = true
                case .disconnected(let error):
                    self?.connectionState = .failed(error)
                    self?.needsApplicationSynchronization = true
                    self?.isHandlingAppFetch = false
                    self?.applicationManagementOperation = nil
                    self?.applicationManagementStatusMessage = nil
                    return
                case .healthSyncCompleted(let succeeded):
                    self?.dataSyncStatusMessage = succeeded ? "Health synchronization completed." : "The watch rejected health synchronization."
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
                case .timelineActionInvoked(let invocation):
                    Task { [weak self] in
                        guard let self, let index = self.timelinePins.firstIndex(where: { $0.id == invocation.itemID }) else { return }
                        self.timelinePins.remove(at: index)
                        try? await self.timelineLibrary.save(self.timelinePins)
                    }
                }
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

    private func handleAppMessage(_ message: AppMessageData) async {
        do {
            guard let application = (watchApplications + watchfaces).first(where: {
                $0.id == message.applicationID
            }), let source = try await applicationLibrary.companionJavaScript(
                applicationID: application.id
            ) else {
                try await client.respondToAppMessage(
                    transactionID: message.transactionID,
                    acknowledged: false
                )
                return
            }
            try await companionRuntime.load(source: source, application: application)
            try await companionRuntime.deliver(message)
            try await client.respondToAppMessage(
                transactionID: message.transactionID,
                acknowledged: true
            )
        } catch {
            try? await client.respondToAppMessage(
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
        guard connectedDevice != nil, !pendingNotifications.isEmpty else { return }
        var remaining: [PebbleTimelineNotification] = []
        for (index, notification) in pendingNotifications.enumerated() {
            do {
                try await client.sendNotification(notification)
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
        guard connectedDevice != nil else {
            pendingAppMessages.append(StoredAppMessage(applicationID: applicationID, tuples: tuples))
            if pendingAppMessages.count > 50 { pendingAppMessages.removeFirst(pendingAppMessages.count - 50) }
            try await pendingAppMessageLibrary.save(pendingAppMessages)
            return
        }
        try await client.sendAppMessage(applicationID: applicationID, tuples: tuples)
    }

    private func flushPendingAppMessages() async {
        guard connectedDevice != nil else { return }
        while let message = pendingAppMessages.first {
            do {
                try await client.sendAppMessage(applicationID: message.applicationID, tuples: message.tuples)
                pendingAppMessages.removeFirst()
            } catch { break }
        }
        try? await pendingAppMessageLibrary.save(pendingAppMessages)
    }

    private func resumePendingFirmwareUpdate() async {
        guard connectedDevice != nil,
              UserDefaults.standard.object(forKey: "autoResumeFirmwareUpdate") as? Bool ?? true,
              let package = try? await pendingFirmwareUpdateLibrary.package() else { return }
        do {
            firmwareUpdateStatusMessage = "Resuming interrupted firmware update…"
            try await client.installFirmware(package)
            await pendingFirmwareUpdateLibrary.clear()
            firmwareUpdateStatusMessage = "Firmware update resumed successfully."
        } catch {
            firmwareUpdateStatusMessage = "Firmware update remains queued for reconnection."
        }
    }

    private func beginHandlingAppFetchRequest(_ request: AppFetchRequest) {
        let operationAllowsFetch = applicationManagementOperation == nil
            || applicationManagementOperation == .synchronizing
            || pendingImportSnapshots[request.applicationID] != nil
        guard appFetchTask == nil, operationAllowsFetch else {
            Task { try? await client.respondToAppFetch(with: .busy) }
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
            await self.handleAppFetchRequest(request)
            self.appFetchTask = nil
            self.isHandlingAppFetch = false
            if ownsOperation {
                self.finishApplicationOperation(.installing(request.applicationID))
            }
        }
    }

    private func handleAppFetchRequest(_ request: AppFetchRequest) async {
        guard let connectedDevice,
              let packageURL = await applicationLibrary.storedPackageURL(
                applicationID: request.applicationID
              ) else {
            try? await client.respondToAppFetch(with: .noData)
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
            let model = connectedDevice.model
            let package = try await Task.detached(priority: .userInitiated) {
                try PBWPackageImporter.load(from: packageURL, for: model)
            }.value
            guard package.application.id == request.applicationID else {
                try await client.respondToAppFetch(with: .invalidApplicationID)
                throw ApplicationManagementError.applicationIDMismatch
            }

            try await client.respondToAppFetch(with: .start)
            for object in package.objects {
                try await client.installApplicationObject(
                    [UInt8](object.data),
                    objectType: object.installationObject.objectType,
                    appBankID: request.appBankID
                )
            }
            try await client.registerApplication(package.appMetadata)
            let applications = try await applicationLibrary.applications()
            try await client.reorderApplications(
                compatibleApplications(applications, with: connectedDevice.model).map(\.id)
            )
            try await recordSynchronizedApplications(applications, device: connectedDevice)
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
                    model: connectedDevice.model
                )
            }
            applicationLibraryErrorMessage = applicationErrorMessage(error)
            try? await client.respondToAppFetch(with: .noData)
        }
    }
}

public enum ApplicationManagementError: Error, Equatable, Sendable {
    case missingStoredPackage(String)
    case applicationIDMismatch
}
