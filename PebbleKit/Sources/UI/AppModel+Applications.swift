import Algorithms
public import API
import AsyncOperations
import Defaults
public import Foundation
import Retry
import SwiftUI

/// The installed application library and its transfers to a watch.
extension AppModel {
    func openConfigurationURL(_ url: URL) {
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

    public var isApplicationManagementBusy: Bool {
        applicationManagementOperation != nil || isHandlingAppFetch
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
            applicationLibraryErrorMessage = "The application library could not be read: \(error.localizedDescription)"
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
                try await retry(with: .watchWork) {
                    try await client.launchApplication(id: application.id)
                }
            }
            activeWatchfaceID = application.id
            Defaults[.activeWatchfaceID] = application.id
            applicationManagementStatusMessage = "\(application.displayName) is active."
        } catch {
            applicationLibraryErrorMessage = "The watchface could not be activated."
        }
    }

    public func toggleFavoriteWatchface(_ application: PebbleApplication) {
        guard application.kind == .watchface else { return }
        if favoriteWatchfaceIDs.contains(application.id) { favoriteWatchfaceIDs.remove(application.id) }
        else { favoriteWatchfaceIDs.insert(application.id) }
        Defaults[.favoriteWatchfaceIDs] = Array(favoriteWatchfaceIDs)
    }

    public func closeConfiguration(response: String? = nil) async {
        try? await companionRuntime.closeConfiguration(response: response)
        configurationURL = nil
        configurationApplication = nil
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
                // The watch only asks for the binary when it tries to run the
                // app, so launching it is what actually starts the transfer.
                for connection in activeConnections
                where compatibleApplications([application], with: connection.device.model).isEmpty == false {
                    try? await connection.client.launchApplication(id: application.id)
                }
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

    func move(
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
        applications = applications.indexed().compactMap { index, application in
            fromOffsets.contains(index) ? nil : application
        }
        let removedBeforeDestination = fromOffsets.count { $0 < toOffset }
        let insertionIndex = toOffset - removedBeforeDestination
        applications.insert(contentsOf: movingApplications, at: insertionIndex)
        return true
    }

    func beginApplicationOperation(_ operation: ApplicationManagementOperation) -> Bool {
        guard applicationManagementOperation == nil, !isHandlingAppFetch else {
            applicationLibraryErrorMessage = "Another application operation is already in progress."
            return false
        }
        applicationManagementOperation = operation
        applicationManagementStatusMessage = statusMessage(for: operation)
        return true
    }

    func finishApplicationOperation(_ operation: ApplicationManagementOperation) {
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
    func synchronizeAllWatches() async throws {
        for connection in activeConnections {
            try await performApplicationSynchronization(on: connection)
        }
    }

    func synchronizeApplications(on connection: WatchConnection) async {
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

    func performApplicationSynchronization(on connection: WatchConnection) async throws {
        let device = connection.device
        let applications = try await applicationLibrary.applications()
        let synchronizedIDs = try await applicationLibrary.synchronizedApplicationIDs(deviceID: device.id)
        let compatibleApplications = compatibleApplications(applications, with: device.model)
        let localIDs = Set(compatibleApplications.map(\.id))
        for applicationID in synchronizedIDs where !localIDs.contains(applicationID) {
            try await connection.client.unregisterApplication(applicationID: applicationID)
        }
        // Reading and unzipping a package is disk work that has nothing to do
        // with the watch, so the packages are decoded a few at a time while
        // `asyncMap` keeps them in library order. The watch is then handed them
        // one by one, because the order they arrive in is the order they appear
        // in its menu.
        let library = applicationLibrary
        let watchModel = device.model
        let packages = try await compatibleApplications
            .asyncMap(numberOfConcurrentTasks: 4) { application in
                guard let packageURL = await library.storedPackageURL(applicationID: application.id) else {
                    throw ApplicationManagementError.missingStoredPackage(application.displayName)
                }
                return try PBWPackageImporter.load(from: packageURL, for: watchModel)
            }
        for package in packages {
            try await connection.client.registerApplication(package.appMetadata)
        }
        try await connection.client.reorderApplications(compatibleApplications.map(\.id))
        try await recordSynchronizedApplications(applications, device: device)
        updateApplications(applications)
    }

    public func installedApplicationIDs(on deviceID: String) -> Set<UUID> {
        installedApplicationIDsByWatch[deviceID] ?? []
    }

    func recordSynchronizedApplications(
        _ applications: [PebbleApplication],
        device: PebbleDevice
    ) async throws {
        let synchronizedIDs = compatibleApplications(applications, with: device.model).map(\.id)
        try await applicationLibrary.setSynchronizedApplicationIDs(
            synchronizedIDs,
            deviceID: device.id
        )
        installedApplicationIDsByWatch[device.id] = Set(synchronizedIDs)
    }

    func compatibleApplications(
        _ applications: [PebbleApplication],
        with model: PebbleWatchModel
    ) -> [PebbleApplication] {
        applications.filter { $0.bestVariant(for: model) != nil }
    }

    func loadPackage(from url: URL, for model: PebbleWatchModel) async throws -> PBWPackage {
        try await Task.detached(priority: .userInitiated) {
            try PBWPackageImporter.load(from: url, for: model)
        }.value
    }

    func expirePendingSnapshot(applicationID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.pendingImportSnapshots[applicationID] = nil
        }
    }

    func statusMessage(for operation: ApplicationManagementOperation) -> LocalizedStringKey {
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

    func applicationErrorMessage(_ error: any Error) -> LocalizedStringKey {
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

    func updateApplications(_ applications: [PebbleApplication]) {
        watchApplications = applications.filter { $0.kind == .watchapp }
        watchfaces = applications.filter { $0.kind == .watchface }
    }

    func beginHandlingAppFetchRequest(
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

    func handleAppFetchRequest(
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
        applicationTransferDeviceID = connection.device.id
        connection.beginTransfer()
        defer {
            installingApplicationID = nil
            installingApplicationName = nil
            applicationTransferDeviceID = nil
            connection.endTransfer()
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
            // The watch installs the binary itself once the transfer commits;
            // re-registering or reordering here only risks undoing it.
            let applications = try await applicationLibrary.applications()
            try await recordSynchronizedApplications(applications, device: connection.device)
            pendingImportSnapshots[request.applicationID] = nil
            applicationLibraryErrorMessage = nil
        } catch {
            pendingImportSnapshots[request.applicationID] = nil
            applicationLibraryErrorMessage = applicationErrorMessage(error)
            try? await connection.client.respondToAppFetch(with: .noData)
        }
    }
}
