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

    private let client: any PebbleClient
    private let applicationLibrary: PebbleApplicationLibrary
    @ObservationIgnored private var connectionEventsTask: Task<Void, Never>?
    @ObservationIgnored private var appFetchTask: Task<Void, Never>?
    @ObservationIgnored private var hasLoadedApplications = false
    @ObservationIgnored private var pendingImportSnapshots: [UUID: PebbleApplicationLibrarySnapshot] = [:]
    @ObservationIgnored private var needsApplicationSynchronization = false

    public init(
        client: any PebbleClient,
        applicationLibrary: PebbleApplicationLibrary = PebbleApplicationLibrary()
    ) {
        self.client = client
        self.applicationLibrary = applicationLibrary
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

    public func scan() async {
        connectionState = .scanning

        do {
            discoveredDevices = try await client.scan()
            connectionState = .idle
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
            observeConnectionEvents()
            await synchronizeApplications(with: connectedDevice)
        } catch let error as PebbleConnectionError {
            connectionState = .failed(error)
        } catch {
            connectionState = .failed(.protocolNegotiationFailed)
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
                        await self?.synchronizeApplications(with: device)
                    }
                case .appFetchRequested(let request):
                    self?.beginHandlingAppFetchRequest(request)
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
                }
            }
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
