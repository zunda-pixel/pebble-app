public import PebbleProtocol
import Defaults
public import Foundation
import SwiftUI

extension AppModel {
    /// Staging matters for a watch running its recovery firmware: it stays
    /// connected for only a few seconds at a time, which is not long enough to
    /// choose a file in.
    public func installFirmware(from url: URL, watchID: WatchID) async {
        // Before anything is staged: the transfer under way reads its journal
        // as it goes, and its success clears it.
        guard !isFirmwareUpdateRunning else {
            firmware[watchID].feedback = .failure("This firmware is already being transferred.")
            return
        }
        let connection = connection(for: watchID).flatMap { $0.isConnected ? $0 : nil }
        let target: FirmwareTarget
        if let connection, let board = connection.watch.board {
            let watch = connection.watch
            target = FirmwareTarget(
                watchID: watch.id,
                board: board,
                firmwareVersion: watch.firmwareVersion,
                slot: watch.firmwareUpdateSlot
            )
        } else if let saved = savedWatch(for: watchID), let board = saved.board {
            // The slot is only known while connected; without it any manifest for this
            // board is accepted and the watch has the last word.
            target = FirmwareTarget(
                watchID: saved.id,
                board: board,
                firmwareVersion: saved.firmwareVersion,
                slot: nil
            )
        } else {
            firmware[watchID].feedback = .failure(
                "Connect the target Pebble once so its board is known, then choose firmware."
            )
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            firmware[watchID].feedback = .progress("Validating firmware…")
            let package = try await Task.detached { [board = target.board, slot = target.slot] in
                try PBZFirmwareImporter.load(from: url, board: board, targetSlot: slot)
            }.value
            try package.validateIntegrity()
            let journal = FirmwareUpdateJournal(
                watchID: target.watchID,
                board: target.board,
                slot: target.slot,
                previousVersion: target.firmwareVersion,
                targetVersion: package.manifest.firmware.versionTag,
                packageFileName: try await firmwarePackageStore.fileName(keeping: url),
                packageSHA256: package.sha256
            )
            try await pendingFirmwareUpdateStore.save(journal)
            firmware[watchID].journal = journal
            if package.manifest.firmware.type == .recovery {
                firmware[watchID].requiresConfirmation = true
                firmware[watchID].feedback = .progress("Recovery firmware validated. Confirm to continue.")
                return
            }
            guard let connection else {
                firmware[watchID].feedback = .success(
                    "Firmware ready. It installs as soon as the watch connects."
                )
                return
            }
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware[watchID].feedback = .failure("Firmware update stopped safely: \(failureReason(for: error))")
        }
    }

    public func checkForFirmwareUpdate(watchID: WatchID) async {
        guard let board = board(for: watchID) else {
            firmware[watchID].feedback = .failure(
                "Connect the target Pebble once so its board is known, then check for firmware."
            )
            return
        }
        do {
            firmware[watchID].feedback = .progress("Looking for published firmware…")
            let release = try await firmwareCatalog.latestRelease(for: board)
            firmware[watchID].availableRelease = release
            // Nothing to say on success: the screen asks every time it opens,
            // and a newer release already shows as the screen's status.
            firmware[watchID].feedback = nil
        } catch {
            firmware[watchID].availableRelease = nil
            firmware[watchID].feedback = .failure("Published firmware could not be checked right now.")
        }
    }

    /// A separate step from installing: the download only needs the network, the
    /// install needs the watch.
    public func downloadAvailableFirmware(watchID: WatchID) async {
        guard let release = firmware[watchID].availableRelease, release.board == board(for: watchID) else {
            await checkForFirmwareUpdate(watchID: watchID)
            guard let checked = firmware[watchID].availableRelease, checked.board == board(for: watchID) else { return }
            await downloadAvailableFirmware(watchID: watchID)
            return
        }
        do {
            firmware[watchID].feedback = .progress("Downloading PebbleOS \(release.versionTag)…")
            let downloaded = DownloadedFirmware(versionTag: release.versionTag, board: release.board)
            try await firmwareCatalog.download(release, to: firmwarePackageStore.url(for: downloaded))
            firmware.downloads = await firmwarePackageStore.downloads()
            firmware[watchID].feedback = .success("PebbleOS \(downloaded.versionTag) is ready to install.")
        } catch {
            firmware[watchID].feedback = .failure("Firmware could not be downloaded right now.")
        }
    }

    /// The package downloaded for this watch's board, if there is one.
    public func downloadedFirmware(for watchID: WatchID) -> DownloadedFirmware? {
        guard let board = board(for: watchID) else { return nil }
        return firmware.download(for: board)
    }

    public func installDownloadedFirmware(watchID: WatchID) async {
        guard let downloaded = downloadedFirmware(for: watchID) else {
            firmware[watchID].feedback = .failure("Download the firmware first.")
            return
        }
        await installFirmware(from: firmwarePackageStore.url(for: downloaded), watchID: watchID)
    }

    /// What was left on disk: each watch's staged update, and the downloads.
    func loadFirmwareState() async {
        let journals = (try? await pendingFirmwareUpdateStore.journals()) ?? [:]
        for (watchID, journal) in journals {
            firmware[watchID].journal = journal
        }
        firmware.downloads = await firmwarePackageStore.downloads()
    }

    func board(for watchID: WatchID?) -> WatchBoard? {
        if let connection = connection(for: watchID), let board = connection.watch.board {
            return board
        }
        return savedWatch(for: watchID)?.board
    }

    func savedWatch(for watchID: WatchID?) -> SavedWatch? {
        guard let watchID else {
            return watches.saved.count == 1 ? watches.saved.first : nil
        }
        return watches.saved.first { $0.id == watchID }
    }

    /// The watch something is for when nothing named one: the connected one,
    /// else the only one there is. A link opened from elsewhere names none.
    var defaultWatchID: WatchID? {
        activeConnections.first?.watch.id ?? savedWatch(for: nil)?.id
    }

    public func confirmRecoveryFirmwareUpdate(watchID: WatchID) async {
        guard firmware[watchID].requiresConfirmation,
              let journal = try? await pendingFirmwareUpdateStore.journal(for: watchID),
              let package = try? await pendingFirmwareUpdateStore.package(for: journal) else { return }
        guard let connection = connection(for: watchID), connection.isConnected else {
            firmware[watchID].feedback = .failure("Connect the watch to resume its firmware update.")
            return
        }
        firmware[watchID].requiresConfirmation = false
        do { try await performFirmwareUpdate(package, on: connection) }
        catch is CancellationError {}
        catch {
            firmware[watchID].feedback = .failure(
                "Recovery update stopped safely: \(failureReason(for: error))"
            )
        }
    }

    /// Stops the transfer only if it is this watch's: the one update that may
    /// run at a time can belong to another watch.
    private func stopFirmwareTransfer(for watchID: WatchID) {
        guard firmwareUpdateWatchID == nil || firmwareUpdateWatchID == watchID else { return }
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        firmwareUpdateClaim = nil
        firmwareUpdateWatchID = nil
    }

    public func cancelFirmwareUpdate(watchID: WatchID) async {
        stopFirmwareTransfer(for: watchID)
        firmware[watchID].requiresConfirmation = false
        try? await pendingFirmwareUpdateStore.updatePhase(.cancelled, watchID: watchID)
        firmware[watchID].journal = try? await pendingFirmwareUpdateStore.journal(for: watchID)
        firmware[watchID].feedback = .success("Firmware update cancelled; recovery data was retained.")
        if firmware[watchID].journal != nil, connection(for: watchID) != nil {
            await disconnect(watchID: watchID)
        }
    }

    public func discardPendingFirmwareUpdate(watchID: WatchID) async {
        stopFirmwareTransfer(for: watchID)
        await pendingFirmwareUpdateStore.clear(watchID: watchID)
        firmware[watchID].journal = nil
        firmware[watchID].requiresConfirmation = false
        firmware[watchID].feedback = .success("Pending firmware update removed.")
    }

    var isFirmwareUpdateRunning: Bool {
        firmwareUpdateClaim != nil || firmwareUpdateTask != nil
    }

    /// Throws `CancellationError` when the reader cancelled it part-way, for a
    /// caller to stay quiet about: `cancelFirmwareUpdate` has already said so.
    func performFirmwareUpdate(
        _ package: PBZFirmwarePackage,
        on connection: WatchConnection
    ) async throws {
        let watchID = connection.watch.id
        // One at a time. Two can be asked for at once — a staged update starting
        // itself as the watch reconnects, while the reader taps Install — and the
        // second would take over the task and flags the first is using. Claimed
        // before the first suspension: with one in the gap, both callers passed
        // the guard and the loser's cleanup ended the winner's transfer (found in
        // the 2026-09-12 audit).
        guard !isFirmwareUpdateRunning else {
            firmware[watchID].feedback = .failure("This firmware is already being transferred.")
            return
        }
        let claim = UUID()
        firmwareUpdateClaim = claim
        firmwareUpdateWatchID = watchID
        defer {
            if firmwareUpdateClaim == claim {
                firmwareUpdateClaim = nil
                firmwareUpdateWatchID = nil
            }
        }
        // The update this notification announced is now under way; a banner
        // for it outlived its purpose the moment the transfer started.
        await localNotifier.remove(
            identifier: Self.firmwareNotificationIdentifier(for: watchID)
        )
        try package.validateIntegrity()
        guard let journal = try await pendingFirmwareUpdateStore.journal(for: watchID),
              journal.packageSHA256 == package.sha256 else {
            throw PBZFirmwareError.unsafeManifest
        }
        guard firmwareUpdateClaim == claim else { throw CancellationError() }
        try await pendingFirmwareUpdateStore.updatePhase(.transferring, watchID: watchID)
        firmware[watchID].journal = try await pendingFirmwareUpdateStore.journal(for: watchID)
        guard firmwareUpdateClaim == claim else { throw CancellationError() }
        firmware[watchID].feedback = .progress("Transferring verified firmware…")
        connection.beginTransfer(.firmware)
        let client = connection.client
        let task = Task { try await client.installFirmware(package) }
        firmwareUpdateTask = task
        defer {
            // A cancelled transfer's handle and bar may already belong to the
            // one started after it.
            if firmwareUpdateClaim == claim {
                firmwareUpdateTask = nil
                connection.endTransfer()
            }
        }
        await DiagnosticLog.shared.record(
            category: "firmware",
            message: "sending \(package.manifest.firmware.versionTag ?? "firmware")"
                + " to \(connection.watch.name)"
                + (connection.watch.isRunningRecoveryFirmware ? " (recovery firmware)" : "")
        )
        do {
            try await task.value
        } catch {
            await DiagnosticLog.shared.record(
                .warning,
                category: "firmware",
                message: "the transfer stopped: \(error.localizedDescription)"
            )
            guard firmwareUpdateClaim == claim else { throw CancellationError() }
            // So the next connection offers the update again instead of silently
            // starting the whole transfer over.
            let stopped = try? await pendingFirmwareUpdateStore.journal(for: watchID)
            if stopped?.phase == .transferring {
                try? await pendingFirmwareUpdateStore.updatePhase(.failed, watchID: watchID)
                firmware[watchID].journal = try? await pendingFirmwareUpdateStore.journal(for: watchID)
            }
            throw error
        }
        try await pendingFirmwareUpdateStore.updatePhase(.awaitingRestart, watchID: watchID)
        firmware[watchID].journal = try await pendingFirmwareUpdateStore.journal(for: watchID)
        firmware[watchID].feedback = .progress("Firmware installed. Waiting for the watch to restart.")
        await DiagnosticLog.shared.record(
            category: "firmware",
            message: "the watch took the firmware and is restarting"
        )
        await pendingFirmwareUpdateStore.clear(watchID: watchID)
        await discardDownloadedFirmware(matching: package, installedOn: watchID)
    }

    /// The watch that took the firmware is back, so the restart it was waiting
    /// for has happened.
    ///
    /// Nothing else says so. The journal is cleared from disk the moment the
    /// transfer finishes, and the copy held here is what the screens read: left
    /// at `awaitingRestart` it offers Stop and Try Again for an update that is
    /// over, and the watch's own row goes on saying an update is waiting.
    func noteFirmwareUpdateFinished(on watch: ConnectedWatch) {
        guard firmware[watch.id].journal?.phase == .awaitingRestart else { return }
        firmware[watch.id].journal = nil
        firmware[watch.id].feedback = nil
    }

    /// The package on disk has done its job. Left there it keeps telling the
    /// reader that firmware is downloaded and waiting, on a watch that is at that
    /// moment restarting into it — unless another watch's staged update is
    /// still going to read it.
    func discardDownloadedFirmware(matching package: PBZFirmwarePackage, installedOn watchID: WatchID) async {
        guard let board = package.manifest.firmware.board,
              let versionTag = package.manifest.firmware.versionTag else { return }
        let downloaded = DownloadedFirmware(versionTag: versionTag, board: board)
        guard firmware.downloads.contains(downloaded),
              !firmware.watches.contains(where: { id, state in
                  id != watchID && state.journal?.packageFileName == downloaded.fileName
              }) else { return }
        await firmwarePackageStore.remove(fileName: downloaded.fileName)
        firmware.downloads = await firmwarePackageStore.downloads()
    }

    // The only case that runs unasked, which is the whole point of staging one.
    func resumePendingFirmwareUpdate(on connection: WatchConnection) async {
        let watch = connection.watch
        guard let journal = try? await pendingFirmwareUpdateStore.journal(for: watch.id),
              journal.board == watch.board,
              journal.phase != .cancelled,
              let package = try? await pendingFirmwareUpdateStore.package(for: journal) else { return }
        firmware[watch.id].journal = journal
        guard journal.phase.mayStartUnattended else {
            firmware[watch.id].feedback = .failure(
                "The firmware update stopped part-way. Resume it when you are ready."
            )
            return
        }
        if package.manifest.firmware.type == .recovery {
            firmware[watch.id].requiresConfirmation = true
            firmware[watch.id].feedback = .progress("Recovery firmware is ready. Confirm to continue.")
            return
        }
        do {
            firmware[watch.id].feedback = .progress("Installing the firmware chosen for this watch…")
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware[watch.id].feedback = .failure(
                "Firmware update stopped safely: \(failureReason(for: error))"
            )
        }
    }

    static func firmwareNotificationIdentifier(for watchID: WatchID) -> String {
        "firmware-update-\(watchID.rawValue)"
    }

    /// The connect-time check, which tells the phone about an update instead
    /// of waiting for the reader to ask (#102).
    ///
    /// The shape follows the official app's `FirmwareUpdateCheck` and
    /// `FirmwareUpdateUiTracker`: one successful answer per (watch, running
    /// version) is good for fifteen minutes, a failed fetch is not an answer
    /// and caches nothing, and the same release is announced to the same watch
    /// once — across launches, since the announcement is stored. A newer
    /// release replaces the announcement under the same identifier, which is
    /// how "the target version changed" cleans up after the old one.
    func checkFirmwareUpdateUnattended(on connection: WatchConnection) async {
        guard notifyAboutFirmwareUpdatesEnabled else { return }
        let watch = connection.watch
        // A watch in recovery firmware is mid-rescue: what it needs is the
        // resume path with its confirmation, not an advertisement.
        guard !watch.isRunningRecoveryFirmware,
              let board = watch.board,
              let running = watch.firmwareVersion else { return }
        let cacheKey = "\(watch.id.rawValue)|\(running)"
        if let checked = firmwareCheckedAt[cacheKey],
           Date().timeIntervalSince(checked) < 15 * 60 {
            return
        }
        let release: PebbleOSFirmwareRelease
        do {
            release = try await firmwareCatalog.latestRelease(for: board)
        } catch {
            // Not cached: a network that refused is not a catalogue that
            // answered "up to date". Said in the log, because a check that
            // fails silently on every connect looks exactly like one that
            // never ran.
            await DiagnosticLog.shared.record(
                .error,
                category: "firmware",
                message: "The update check could not reach the catalogue: \(String(reflecting: error))"
            )
            return
        }
        firmwareCheckedAt[cacheKey] = Date()
        guard PebbleOSFirmwareCatalog.isVersion(release.versionTag, newerThan: running) else { return }
        guard Defaults[.notifiedFirmwareVersions][watch.id] != release.versionTag else {
            return
        }
        Defaults[.notifiedFirmwareVersions][watch.id] = release.versionTag
        await localNotifier.post(
            identifier: Self.firmwareNotificationIdentifier(for: watch.id),
            title: String(localized: "Firmware Update", bundle: .module),
            body: String(
                localized: "PebbleOS \(release.versionTag) is available for \(watch.name).",
                bundle: .module
            )
        )
    }

    /// The firmware-update notification switch, with the same permission
    /// contract as the charge one: asked for only when turned on, and turned
    /// back off when refused.
    public func setNotifyAboutFirmwareUpdates(_ enabled: Bool) async {
        guard enabled else {
            notifyAboutFirmwareUpdatesEnabled = false
            Defaults[.notifyAboutFirmwareUpdates] = false
            return
        }
        guard await localNotifier.requestAuthorization() else {
            notifyAboutFirmwareUpdatesEnabled = false
            Defaults[.notifyAboutFirmwareUpdates] = false
            phoneAlertsFeedback = .failure(
                "Notifications are turned off for this app in the system settings."
            )
            return
        }
        notifyAboutFirmwareUpdatesEnabled = true
        Defaults[.notifyAboutFirmwareUpdates] = true
        phoneAlertsFeedback = nil
    }

    public func resumeFirmwareUpdate(watchID: WatchID) async {
        guard let journal = try? await pendingFirmwareUpdateStore.journal(for: watchID),
              let package = try? await pendingFirmwareUpdateStore.package(for: journal),
              let connection = connection(for: watchID),
              connection.isConnected else {
            firmware[watchID].feedback = .failure("Connect the watch to resume its firmware update.")
            return
        }
        do {
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware[watchID].feedback = .failure(
                "Firmware update stopped safely: \(failureReason(for: error))"
            )
        }
    }
}

/// The watch a firmware install is aimed at: the connected one if possible,
/// else the remembered one. The journal is written from this, so it carries
/// everything the journal needs.
struct FirmwareTarget {
    var watchID: WatchID
    var board: WatchBoard
    var firmwareVersion: String?
    /// Only known while connected; nil accepts any manifest for the board and
    /// leaves the watch the last word.
    var slot: Int?
}
