import Algorithms
public import PebbleProtocol
import AsyncOperations
import CryptoKit
import Defaults
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    /// Whether a settings page may be opened at all.
    ///
    /// `http` is allowed alongside `https` because the settings pages of the
    /// applications people already own are largely plain: two of the reader's
    /// were refused here, and the official app checks nothing at all
    /// (libpebble3's `PKJSInterface.openURL` hands the string straight to the
    /// web view). The cost is that a page's query string — which can carry the
    /// watch token — travels in the clear, which is why the app carries an App
    /// Transport Security exception for web content and nothing else.
    ///
    /// A page an application built itself and handed over as a `data:` URL is
    /// allowed too, and reaches the web view as HTML rather than as a
    /// navigation: it never touches the network, and refusing it was the second
    /// of the reader's two applications that could not be configured.
    ///
    /// A URL with no host, or with a password in it, is still refused: neither
    /// is something a settings page needs, and both are how a string that is not
    /// a settings page at all tends to look.
    static func mayOpenConfigurationURL(_ url: URL) -> Bool {
        if url.inlineHTML != nil { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http")
            && url.host?.isEmpty == false
            && url.user == nil
            && url.password == nil
    }

    func openConfigurationURL(_ url: URL) {
        guard Self.mayOpenConfigurationURL(url) else {
            applications.libraryFeedback = .failure("The application requested an unsafe settings URL.")
            Task { [
                scheme = url.scheme ?? "none",
                host = url.host ?? "none",
                hasCredentials = url.user != nil || url.password != nil
            ] in
                // Which rule it broke, not the URL: a settings page's query
                // string carries the watch token and the reader's account.
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "Rejected a configuration URL: scheme=\(scheme)"
                        + " host=\(host) credentials=\(hasCredentials)"
                )
            }
            return
        }
        let isReplacing = applications.configurationURL != nil
        applications.configurationURL = url
        Task { [fingerprint = Self.configurationFingerprint(url), isReplacing] in
            // Said because the settings page was loaded twice for one opening
            // and nothing could say whether that was two URLs or one: this line
            // is the difference. Whether it replaced one, and a fingerprint
            // rather than the URL — a settings page's query string carries the
            // watch token and the reader's account, which is the same reason a
            // refusal names the rule it broke and not the address.
            await DiagnosticLog.shared.record(
                category: "configuration",
                message: isReplacing
                    ? "a settings page \(fingerprint) replaced the one already showing"
                    : "showing settings page \(fingerprint)"
            )
        }
    }

    /// Enough of a URL to tell one from another, and nothing that could identify
    /// the reader or their watch.
    static func configurationFingerprint(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(4).hexadecimalString
    }

    public var isApplicationManagementBusy: Bool {
        applications.managementOperation != nil || isHandlingAppFetch
    }

    public func loadApplications() async {
        guard !hasLoadedApplications else {
            return
        }
        hasLoadedApplications = true
        applications.isLoading = true
        defer { applications.isLoading = false }
        do {
            updateApplications(try await applicationLibrary.applications())
            applications.libraryFeedback = nil
        } catch {
            applications.libraryFeedback = .failure("The application library could not be read: \(error.localizedDescription)")
        }
    }

    /// The watch launched an app (#130): a fresh page, so `ready` fires for
    /// this launch the way the PKJS lifecycle promises. The lazy starts on
    /// configuration and on an incoming appmessage remain as the net under a
    /// run-state event that never came.
    func launchCompanionRuntime(applicationID: UUID) async {
        guard let application = (applications.apps + applications.watchfaces)
            .first(where: { $0.id == applicationID }),
            application.hasCompanionJavaScript,
            let source = ((try? await applicationLibrary.companionJavaScript(applicationID: applicationID)) ?? nil)
        else { return }
        try? await companionRuntime.relaunch(source: source, application: application)
    }

    public func configureApplication(_ application: WatchApplication) async {
        guard application.isConfigurable else { return }
        do {
            guard let source = try await applicationLibrary.companionJavaScript(
                applicationID: application.id
            ) else { return }
            applications.configurationApplication = application
            applications.configurationURL = nil
            try await companionRuntime.load(source: source, application: application)
            try await companionRuntime.showConfiguration()
            await DiagnosticLog.shared.record(
                category: "configuration",
                message: "Requested configuration for \(application.displayName)"
            )
        } catch {
            applications.libraryFeedback = .failure("The application settings could not be opened.")
        }
    }

    public func activateWatchface(_ application: WatchApplication) async {
        guard application.kind == .watchface else { return }
        guard !activeConnections.isEmpty else {
            // A watchface becomes active by being launched, and there is nothing to
            // launch it on.
            applications.libraryFeedback = .failure("Connect a Pebble to change the watchface.")
            return
        }
        do {
            for connection in activeConnections {
                let client = connection.client
                try await retry(with: .watchWork) {
                    try await client.launchApplication(id: application.id)
                }
            }
            applications.activeWatchfaceID = application.id
            Defaults[.activeWatchfaceID] = application.id
            applications.managementFeedback = .success("\(application.displayName) is active.")
        } catch {
            applications.libraryFeedback = .failure("The watchface could not be activated.")
        }
    }

    public func closeConfiguration(response: String? = nil) async {
        try? await companionRuntime.closeConfiguration(response: response)
        applications.configurationURL = nil
        applications.configurationApplication = nil
    }

    public func removeApplication(id: UUID) async {
        if applications.activeWatchfaceID == id {
            guard let fallback = applications.watchfaces.first(where: { $0.id != id }) else {
                applications.libraryFeedback = .failure("Install and activate another watchface before removing the active one.")
                return
            }
            if activeConnections.isEmpty {
                // The active watchface is remembered from the last session, so this is the
                // ordinary offline case: record the choice and let the next connection
                // register the library as it then stands.
                applications.activeWatchfaceID = fallback.id
                Defaults[.activeWatchfaceID] = fallback.id
            } else {
                await activateWatchface(fallback)
                guard applications.activeWatchfaceID == fallback.id else { return }
            }
        }
        guard beginApplicationOperation(.removing(id)) else { return }
        defer { finishApplicationOperation(.removing(id)) }
        do {
            let library = try await applicationLibrary.remove(applicationID: id)
            updateApplications(library)
            try await synchronizeAllWatches()
            // What the application's own JavaScript kept goes with it. Left
            // behind, it would come back as the old settings of the same watch
            // app installed again.
            await PebbleCompanionRuntime.forget(applicationID: id)
            applications.libraryFeedback = nil
        } catch {
            applications.libraryFeedback = .failure(applicationErrorMessage(error))
        }
    }

    public func importApplication(from url: URL) async {
        guard beginApplicationOperation(.importing) else { return }
        applications.isImporting = true
        defer {
            applications.isImporting = false
            finishApplicationOperation(.importing)
        }
        let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var importedApplicationID: UUID?
        do {
            let application = try await Task.detached(priority: .userInitiated) {
                try PBWPackageImporter.application(from: url)
            }.value
            importedApplicationID = application.id
            let snapshot = try await applicationLibrary.snapshot(applicationID: application.id)
            let library = try await applicationLibrary.importPackage(from: url)
            updateApplications(library)
            if !activeConnections.isEmpty {
                pendingImportSnapshots[application.id] = snapshot
                try await synchronizeAllWatches()
                // The watch only asks for the binary when it tries to run the app.
                for connection in activeConnections {
                    guard let model = connection.watch.model,
                          !compatibleApplications([application], with: model).isEmpty else { continue }
                    try? await connection.client.launchApplication(id: application.id)
                }
                expirePendingSnapshot(applicationID: application.id)
            }
            hasLoadedApplications = true
            // Silent on success — the row appearing in the library says it,
            // and the banner only repeated it (owner feedback, 2026-09-12).
            // Cleared rather than left, so a stale failure does not outlive
            // the import that succeeded after it. Failures still speak below.
            applications.importFeedback = nil
        } catch {
            // The watch refused the registration, not the bytes, so nothing has been
            // transferred and the import stands.
            if let importedApplicationID {
                expirePendingSnapshot(applicationID: importedApplicationID)
            }
            applications.importFeedback = .failure(applicationErrorMessage(error))
        }
    }

    public func reorderApplications(
        kind: WatchApplicationKind,
        fromOffsets: IndexSet,
        toOffset: Int
    ) async {
        guard beginApplicationOperation(.reordering) else { return }
        defer { finishApplicationOperation(.reordering) }
        var selectedApplications = kind == .watchapp ? applications.apps : applications.watchfaces
        guard move(&selectedApplications, fromOffsets: fromOffsets, toOffset: toOffset) else {
            return
        }
        let orderedApplications = kind == .watchapp
            ? selectedApplications + applications.watchfaces
            : applications.apps + selectedApplications

        do {
            let previousApplications = try await applicationLibrary.applications()
            let reordered = try await applicationLibrary.reorder(
                applicationIDs: orderedApplications.map(\.id)
            )
            updateApplications(reordered)
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
            applications.libraryFeedback = nil
        } catch {
            applications.libraryFeedback = .failure(applicationErrorMessage(error))
        }
    }

    func move(
        _ applications: inout [WatchApplication],
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
        guard applications.managementOperation == nil, !isHandlingAppFetch else {
            applications.libraryFeedback = .failure("Another application operation is already in progress.")
            return false
        }
        applications.managementOperation = operation
        applications.managementFeedback = .progress(statusMessage(for: operation))
        return true
    }

    func finishApplicationOperation(_ operation: ApplicationManagementOperation) {
        guard applications.managementOperation == operation else { return }
        let completedOperation = applications.managementOperation
        applications.managementOperation = nil
        applications.managementFeedback = nil
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
            applications.libraryFeedback = nil
        } catch {
            needsApplicationSynchronization = true
            applications.libraryFeedback = .failure(applicationErrorMessage(error))
        }
    }

    func performApplicationSynchronization(on connection: WatchConnection) async throws {
        let watch = connection.watch
        // With no model there is no way to pick a variant, and an empty
        // "compatible" list here would read as "remove everything this watch
        // was given". Leaving the watch alone is the smaller wrong.
        guard let watchModel = watch.model else {
            await DiagnosticLog.shared.record(
                .warning,
                category: "application",
                message: "\(watch.name) has no known model; leaving its applications untouched"
            )
            return
        }
        let installed = try await applicationLibrary.applications()
        let synchronizedIDs = try await applicationLibrary.synchronizedApplicationIDs(watchID: watch.id)
        let compatibleApplications = compatibleApplications(installed, with: watchModel)
        let localIDs = Set(compatibleApplications.map(\.id))
        var dropped = 0
        for applicationID in synchronizedIDs where !localIDs.contains(applicationID) {
            try await connection.client.remove(.application(applicationID))
            dropped += 1
        }
        // Reading and unzipping a package is disk work with nothing to do with the
        // watch, so a few run at once while `asyncMap` keeps them in library order.
        let library = applicationLibrary
        let packages = try await compatibleApplications
            .asyncMap(numberOfConcurrentTasks: 4) { application in
                guard let packageURL = await library.storedPackageURL(applicationID: application.id) else {
                    throw ApplicationManagementError.missingStoredPackage(application.displayName)
                }
                return try PBWPackageImporter.load(from: packageURL, for: watchModel)
            }
        for package in packages {
            try await connection.client.write(.application(package.appMetadata))
        }
        try await connection.client.reorderApplications(compatibleApplications.map(\.id))
        try await recordSynchronizedApplications(installed, watch: watch)
        updateApplications(installed)
        // The whole compatible library is registered on every synchronization, so
        // the count is the library as this watch now sees it, not a delta.
        await DiagnosticLog.shared.record(
            category: "application",
            message: "\(watch.name) took \(packages.count) registration(s) and dropped \(dropped)"
        )
    }

    public func installedApplicationIDs(on watchID: WatchID) -> Set<UUID> {
        applications.installedIDsByWatch[watchID] ?? []
    }

    func recordSynchronizedApplications(
        _ library: [WatchApplication],
        watch: ConnectedWatch
    ) async throws {
        // No model means the synchronization above never ran; there is nothing
        // to record.
        guard let model = watch.model else { return }
        let synchronizedIDs = compatibleApplications(library, with: model).map(\.id)
        try await applicationLibrary.setSynchronizedApplicationIDs(
            synchronizedIDs,
            watchID: watch.id
        )
        applications.installedIDsByWatch[watch.id] = Set(synchronizedIDs)
    }

    func compatibleApplications(
        _ applications: [WatchApplication],
        with model: WatchModel
    ) -> [WatchApplication] {
        applications.filter { $0.bestVariant(for: model) != nil }
    }

    func loadPackage(from url: URL, for model: WatchModel) async throws -> PBWPackage {
        try await Task.detached(priority: .userInitiated) {
            try PBWPackageImporter.load(from: url, for: model)
        }.value
    }

    func restorePendingSnapshot(applicationID: UUID) async {
        guard let snapshot = pendingImportSnapshots.removeValue(forKey: applicationID) else {
            return
        }
        do {
            updateApplications(try await applicationLibrary.restore(snapshot))
        } catch {
            await DiagnosticLog.shared.record(
                .error,
                category: "application",
                message: "Could not restore the application library after a failed transfer: "
                    + String(reflecting: error)
            )
        }
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
        case let error as WatchConnectionError:
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
            "The watch rejected the application data. The application library was left as it was."
        case is PutBytesTransferError, is PutBytesCodecError:
            "The application transfer was interrupted. The application library was left as it was."
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

    func updateApplications(_ library: [WatchApplication]) {
        applications.apps = library.filter { $0.kind == .watchapp }
        applications.watchfaces = library.filter { $0.kind == .watchface }
    }

    func beginHandlingAppFetchRequest(
        _ request: AppFetchRequest,
        from connection: WatchConnection
    ) {
        let operationAllowsFetch = applications.managementOperation == nil
            || applications.managementOperation == .synchronizing
            || pendingImportSnapshots[request.applicationID] != nil
        // This watch's own request, not any watch's: another watch waiting for an
        // app of its own is no reason to answer this one with "busy".
        guard !connection.isFetchingApplication, operationAllowsFetch else {
            Task { try? await connection.client.respondToAppFetch(with: .busy) }
            return
        }
        let ownsOperation = applications.managementOperation == nil
            || pendingImportSnapshots[request.applicationID] != nil
        if ownsOperation {
            applications.managementOperation = .installing(request.applicationID)
            applications.managementFeedback = .progress(statusMessage(for: .installing(request.applicationID)))
        }
        connection.appFetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.handleAppFetchRequest(request, from: connection)
            connection.appFetchTask = nil
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
            await restorePendingSnapshot(applicationID: request.applicationID)
            try? await connection.client.respondToAppFetch(with: .noData)
            return
        }

        // A fetch names a variant to send, and without a model there is no way
        // to choose one; "no data" lets the watch stop waiting.
        guard let model = connection.watch.model else {
            try? await connection.client.respondToAppFetch(with: .noData)
            return
        }

        connection.beginTransfer(.application(request.applicationID))
        defer { connection.endTransfer() }

        do {
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
            let library = try await applicationLibrary.applications()
            try await recordSynchronizedApplications(library, watch: connection.watch)
            pendingImportSnapshots[request.applicationID] = nil
            applications.libraryFeedback = nil
            // The only record that a transfer finished: the watch commits and
            // installs the binary itself, and says nothing back about it.
            await DiagnosticLog.shared.record(
                category: "application",
                message: "\(connection.watch.name) took \(package.objects.count) object(s)"
                    + " of \(package.application.displayName)"
            )
        } catch {
            // Including when "the version they had" is none at all and the import has
            // to be undone entirely.
            await restorePendingSnapshot(applicationID: request.applicationID)
            applications.libraryFeedback = .failure(applicationErrorMessage(error))
            try? await connection.client.respondToAppFetch(with: .noData)
        }
    }
}
