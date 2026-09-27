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
            applications.libraryFeedback = .failure("The app requested an unsafe settings URL.")
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
        applications.isLoading = true
        defer { applications.isLoading = false }
        do {
            updateApplications(try await applicationLibrary.applications())
            hasLoadedApplications = true
            applications.libraryFeedback = nil
        } catch {
            applications.libraryFeedback = .failure("The app library could not be read: \(failureReason(for: error))")
        }
    }

    /// The watch launched an app (#130): a fresh page, so `ready` fires for
    /// this launch the way the PKJS lifecycle promises. The lazy starts on
    /// configuration and on an incoming appmessage remain as the net under a
    /// run-state event that never came.
    func launchCompanionRuntime(applicationID: UUID, on watchID: WatchID) async {
        guard let application = applications.all
            .first(where: { $0.id == applicationID }),
            application.hasCompanionJavaScript,
            let source = ((try? await applicationLibrary.companionJavaScript(applicationID: applicationID)) ?? nil)
        else { return }
        companionRuntimeWatchID = watchID
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
            applications.libraryFeedback = .failure("The app's settings could not be opened.")
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
                applications.activeWatchfaceIDs[connection.watch.id] = application.id
            }
            Defaults[.activeWatchfaceIDs] = applications.activeWatchfaceIDs
            // Beside its failure, so the one never sits on screen under the
            // other: `managementFeedback` is the running operation's, and the
            // next one to start or finish replaces it.
            applications.libraryFeedback = .success("\(application.displayName) is active.")
        } catch {
            // The watches that did launch it are showing it.
            Defaults[.activeWatchfaceIDs] = applications.activeWatchfaceIDs
            applications.libraryFeedback = .failure("The watchface could not be activated.")
        }
    }

    public func closeConfiguration(response: String? = nil) async {
        try? await companionRuntime.closeConfiguration(response: response)
        applications.configurationURL = nil
        applications.configurationApplication = nil
    }

    /// False when it is still in the library, with the reason in
    /// `applications.libraryFeedback`.
    @discardableResult
    public func removeApplication(id: UUID) async -> Bool {
        let showingIt = applications.activeWatchfaceIDs.filter { $0.value == id }.map(\.key)
        if !showingIt.isEmpty {
            guard let fallback = applications.watchfaces.first(where: { $0.id != id }) else {
                applications.libraryFeedback = .failure("Install and activate another watchface before removing the active one.")
                return false
            }
            if !activeConnections.isEmpty {
                await activateWatchface(fallback)
                guard activeConnections.allSatisfy({
                    applications.activeWatchfaceIDs[$0.watch.id] == fallback.id
                }) else { return false }
            }
            // A watch that is away was showing it when last seen, which is the
            // ordinary offline case: record the choice and let the next
            // connection register the library as it then stands.
            for watchID in showingIt where applications.activeWatchfaceIDs[watchID] == id {
                applications.activeWatchfaceIDs[watchID] = fallback.id
            }
            Defaults[.activeWatchfaceIDs] = applications.activeWatchfaceIDs
        }
        guard beginApplicationOperation(.removing(id)) else { return false }
        defer { finishApplicationOperation(.removing(id)) }
        do {
            let library = try await applicationLibrary.remove(applicationID: id)
            updateApplications(library)
            try await synchronizeApplicationsOnAllWatches()
            // What the application's own JavaScript kept goes with it. Left
            // behind, it would come back as the old settings of the same watch
            // app installed again.
            await PebbleCompanionRuntime.forget(applicationID: id)
            applications.libraryFeedback = nil
            return true
        } catch {
            applications.libraryFeedback = .failure(applicationErrorMessage(error))
            return !applications.all.contains { $0.id == id }
        }
    }

    @discardableResult
    public func importApplication(from url: URL) async -> Bool {
        guard beginApplicationOperation(.importing) else { return false }
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
                try await synchronizeApplicationsOnAllWatches()
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
            return true
        } catch {
            // The watch refused the registration, not the bytes, so nothing has been
            // transferred and the import stands.
            if let importedApplicationID {
                expirePendingSnapshot(applicationID: importedApplicationID)
            }
            applications.importFeedback = .failure(applicationErrorMessage(error))
            return false
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
                try await synchronizeApplicationsOnAllWatches()
            } catch {
                let restored = try await applicationLibrary.reorder(
                    applicationIDs: previousApplications.map(\.id)
                )
                updateApplications(restored)
                try? await synchronizeApplicationsOnAllWatches()
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

    /// `reportingRefusal` is false for work nobody asked for: a watch arriving
    /// while the library is busy waits its turn, and the reader, who did
    /// nothing, is not told an operation was refused.
    func beginApplicationOperation(
        _ operation: ApplicationManagementOperation,
        reportingRefusal: Bool = true
    ) -> Bool {
        guard applications.managementOperation == nil, !isHandlingAppFetch else {
            if reportingRefusal {
                applications.libraryFeedback = .failure("Another app operation is already in progress.")
            }
            return false
        }
        applications.managementOperation = operation
        applications.managementFeedback = .progress(statusMessage(for: operation))
        return true
    }

    /// Hands the library to the next watch waiting for it, one at a time: that
    /// watch's own finish hands it on again. `synchronized` is the watch the
    /// operation just synchronized, which is not retried at once — a watch
    /// that failed would otherwise be asked again for as long as it failed.
    func finishApplicationOperation(
        _ operation: ApplicationManagementOperation,
        synchronized watchID: WatchID? = nil
    ) {
        guard applications.managementOperation == operation else { return }
        applications.managementOperation = nil
        applications.managementFeedback = nil
        guard let next = activeConnections.first(where: {
            $0.watch.id != watchID && watchesAwaitingApplicationSynchronization.contains($0.watch.id)
        }) else { return }
        Task { [weak self] in
            await self?.synchronizeApplications(on: next)
        }
    }

    /// Every watch is tried, and the first failure thrown once they all have
    /// been: stopping at it left the watches after it holding an app the
    /// library had already let go of, with nothing to bring them round.
    func synchronizeApplicationsOnAllWatches() async throws {
        var firstFailure: (any Error)?
        for connection in activeConnections {
            do {
                try await performApplicationSynchronization(on: connection)
            } catch {
                watchesAwaitingApplicationSynchronization.insert(connection.watch.id)
                firstFailure = firstFailure ?? error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    func synchronizeApplications(on connection: WatchConnection) async {
        guard connection.isConnected else { return }
        let watchID = connection.watch.id
        guard beginApplicationOperation(.synchronizing, reportingRefusal: false) else {
            watchesAwaitingApplicationSynchronization.insert(watchID)
            return
        }
        watchesAwaitingApplicationSynchronization.remove(watchID)
        defer { finishApplicationOperation(.synchronizing, synchronized: watchID) }

        do {
            try await performApplicationSynchronization(on: connection)
            applications.libraryFeedback = nil
        } catch {
            watchesAwaitingApplicationSynchronization.insert(watchID)
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

    func expirePendingSnapshot(applicationID: UUID, after delay: Duration = .seconds(300)) {
        pendingSnapshotExpiries[applicationID]?.cancel()
        pendingSnapshotExpiries[applicationID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingImportSnapshots[applicationID] = nil
            self.pendingSnapshotExpiries[applicationID] = nil
        }
    }

    func statusMessage(for operation: ApplicationManagementOperation) -> LocalizedStringKey {
        switch operation {
        case .importing:
            "Preparing app…"
        case .installing:
            "Installing app…"
        case .removing:
            "Removing app…"
        case .reordering:
            "Updating app order…"
        case .synchronizing:
            "Synchronizing apps…"
        }
    }

    func applicationErrorMessage(_ error: any Error) -> LocalizedStringKey {
        switch error {
        case let error as WatchConnectionError:
            error.message
        case BlobDBClientError.operationAlreadyInProgress:
            "The watch is already processing another app change. Please try again."
        case BlobDBClientError.rejected(.databaseFull):
            "The watch does not have enough space for this app."
        case BlobDBClientError.rejected(.locked), BlobDBClientError.rejected(.tryLater):
            "The watch is busy. Please wait and try again."
        case is BlobDBClientError:
            "The watch rejected the app change."
        case AppReorderClientError.operationAlreadyInProgress:
            "The watch is already updating the app order."
        case AppReorderClientError.rejected(.retry):
            "The watch is busy. Please try changing the app order again."
        case is AppReorderClientError:
            "The watch rejected the app order. The previous order was restored."
        case PutBytesTransferError.negativeAcknowledgement:
            "The watch rejected the app data. The library was left as it was."
        case is PutBytesTransferError, is PutBytesCodecError:
            "The app transfer was interrupted. The app library was left as it was."
        case PBWManifestError.noCompatibleVariant:
            "This app does not support the connected Pebble model."
        case PBWPackageImportError.applicationIDMismatch:
            "The PBW package contains mismatched app identifiers."
        case PBWPackageImportError.missingExecutable:
            "The PBW package does not contain an app executable."
        case is PBWPackageImportError, is PBWManifestError, is PBWBinaryHeaderError, is PBWApplicationError:
            "The selected PBW package is invalid or incomplete."
        case ApplicationManagementError.missingStoredPackage(let name):
            "The stored package for \(name) is missing. Import it again."
        case ApplicationManagementError.applicationIDMismatch:
            "The watch requested an app that does not match the stored PBW package."
        default:
            "The app operation could not be completed. \(failureReason(for: error))"
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
            connection.ownedApplicationOperation = .installing(request.applicationID)
        }
        let token = UUID()
        connection.appFetchToken = token
        connection.appFetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.handleAppFetchRequest(request, from: connection)
            // A fetch cancelled by a reconnect can finish after the watch has
            // asked again on the same link; the handle and the operation are
            // then the new fetch's, not this one's.
            guard connection.appFetchToken == token else { return }
            connection.appFetchTask = nil
            connection.appFetchToken = nil
            if ownsOperation {
                connection.ownedApplicationOperation = nil
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
