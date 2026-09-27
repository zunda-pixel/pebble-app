public import PebbleProtocol
import Defaults
public import Foundation
import SwiftUI

extension AppModel {
    /// Staging matters for a watch running its recovery firmware: it stays
    /// connected for only a few seconds at a time, which is not long enough to
    /// choose a file in.
    public func installFirmware(from url: URL, watchID: WatchID? = nil) async {
        // Before anything is staged: the package and journal on disk belong to
        // the transfer under way, and its success clears whatever is there.
        guard !isFirmwareUpdateRunning else {
            firmware.feedback = .failure("This firmware is already being transferred.")
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
            firmware.feedback = .failure(
                "Connect the target Pebble once so its board is known, then choose firmware."
            )
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            firmware.feedback = .progress("Validating firmware…")
            let package = try await Task.detached { [board = target.board, slot = target.slot] in
                try PBZFirmwareImporter.load(from: url, board: board, targetSlot: slot)
            }.value
            try package.validateIntegrity()
            let journal = FirmwareUpdateJournal(
                watchID: target.watchID,
                board: target.board,
                previousVersion: target.firmwareVersion,
                targetVersion: package.manifest.firmware.versionTag,
                packageSHA256: package.sha256
            )
            try await pendingFirmwareUpdateStore.save(package, journal: journal)
            firmware.journal = journal
            if package.manifest.firmware.type == "recovery" {
                firmware.requiresConfirmation = true
                firmware.feedback = .progress("Recovery firmware validated. Confirm to continue.")
                return
            }
            guard let connection else {
                firmware.feedback = .success(
                    "Firmware ready. It installs as soon as the watch connects."
                )
                return
            }
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware.feedback = .failure("Firmware update stopped safely: \(failureReason(for: error))")
        }
    }

    public func checkForFirmwareUpdate(watchID: WatchID? = nil) async {
        guard let board = board(for: watchID) else {
            firmware.feedback = .failure(
                "Connect the target Pebble once so its board is known, then check for firmware."
            )
            return
        }
        do {
            firmware.feedback = .progress("Looking for published firmware…")
            let release = try await firmwareCatalog.latestRelease(for: board)
            firmware.availableRelease = release
            firmware.feedback = .success("PebbleOS \(release.versionTag) is available.")
        } catch {
            firmware.availableRelease = nil
            firmware.feedback = .failure("Published firmware could not be checked right now.")
        }
    }

    /// A separate step from installing: the download only needs the network, the
    /// install needs the watch.
    public func downloadAvailableFirmware(watchID: WatchID? = nil) async {
        // The release on hand may be another watch's: it is whichever board was
        // checked last, and this watch's importer would refuse its package.
        guard let release = firmware.availableRelease, release.board == board(for: watchID) else {
            await checkForFirmwareUpdate(watchID: watchID)
            guard let checked = firmware.availableRelease, checked.board == board(for: watchID) else { return }
            await downloadAvailableFirmware(watchID: watchID)
            return
        }
        do {
            firmware.feedback = .progress("Downloading PebbleOS \(release.versionTag)…")
            let downloaded = try await firmwareCatalog.download(release)
            firmware.downloaded = downloaded
            Defaults[.downloadedFirmware] = downloaded
            firmware.feedback = .success("PebbleOS \(downloaded.versionTag) is ready to install.")
        } catch {
            firmware.feedback = .failure("Firmware could not be downloaded right now.")
        }
    }

    public func installDownloadedFirmware(watchID: WatchID? = nil) async {
        guard let downloaded = firmware.downloaded, downloaded.board == board(for: watchID) else {
            firmware.feedback = .failure("Download the firmware first.")
            return
        }
        await installFirmware(from: downloaded.url, watchID: watchID)
    }

    func loadDownloadedFirmware() {
        guard let stored = Defaults[.downloadedFirmware] else { return }
        guard FileManager.default.fileExists(atPath: stored.url.path(percentEncoded: false)) else {
            Defaults[.downloadedFirmware] = nil
            return
        }
        firmware.downloaded = stored
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

    public func confirmRecoveryFirmwareUpdate() async {
        guard firmware.requiresConfirmation,
              let package = try? await pendingFirmwareUpdateStore.package(),
              let journal = try? await pendingFirmwareUpdateStore.journal() else { return }
        guard let connection = connection(for: journal.watchID), connection.isConnected else {
            firmware.feedback = .failure("Connect the watch to resume its firmware update.")
            return
        }
        firmware.requiresConfirmation = false
        do { try await performFirmwareUpdate(package, on: connection) }
        catch is CancellationError {}
        catch { firmware.feedback = .failure("Recovery update stopped safely: \(failureReason(for: error))") }
    }

    public func cancelFirmwareUpdate() async {
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        firmwareUpdateClaim = nil
        firmware.requiresConfirmation = false
        try? await pendingFirmwareUpdateStore.updatePhase(.cancelled)
        firmware.journal = try? await pendingFirmwareUpdateStore.journal()
        firmware.feedback = .success("Firmware update cancelled; recovery data was retained.")
        if let watchID = firmware.journal?.watchID,
           let connection = connection(for: watchID) {
            await disconnect(watchID: connection.watch.id)
        }
    }

    public func discardPendingFirmwareUpdate() async {
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        firmwareUpdateClaim = nil
        await pendingFirmwareUpdateStore.clear()
        firmware.journal = nil
        firmware.requiresConfirmation = false
        firmware.feedback = .success("Pending firmware update removed.")
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
        // One at a time. Two can be asked for at once — a staged update starting
        // itself as the watch reconnects, while the reader taps Install — and the
        // second would take over the task and flags the first is using. Claimed
        // before the first suspension: with one in the gap, both callers passed
        // the guard and the loser's cleanup ended the winner's transfer (found in
        // the 2026-09-12 audit).
        guard !isFirmwareUpdateRunning else {
            firmware.feedback = .failure("This firmware is already being transferred.")
            return
        }
        let claim = UUID()
        firmwareUpdateClaim = claim
        defer {
            if firmwareUpdateClaim == claim { firmwareUpdateClaim = nil }
        }
        // The update this notification announced is now under way; a banner
        // for it outlived its purpose the moment the transfer started.
        await localNotifier.remove(
            identifier: Self.firmwareNotificationIdentifier(for: connection.watch.id)
        )
        try package.validateIntegrity()
        guard let journal = try await pendingFirmwareUpdateStore.journal(),
              journal.packageSHA256 == package.sha256,
              journal.watchID == connection.watch.id else {
            throw PBZFirmwareError.unsafeManifest
        }
        guard firmwareUpdateClaim == claim else { throw CancellationError() }
        try await pendingFirmwareUpdateStore.updatePhase(.transferring)
        firmware.journal = try await pendingFirmwareUpdateStore.journal()
        guard firmwareUpdateClaim == claim else { throw CancellationError() }
        firmware.feedback = .progress("Transferring verified firmware…")
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
            let stopped = try? await pendingFirmwareUpdateStore.journal()
            if stopped?.phase == .transferring {
                try? await pendingFirmwareUpdateStore.updatePhase(.failed)
                firmware.journal = try? await pendingFirmwareUpdateStore.journal()
            }
            throw error
        }
        try await pendingFirmwareUpdateStore.updatePhase(.awaitingRestart)
        firmware.journal = try await pendingFirmwareUpdateStore.journal()
        firmware.feedback = .progress("Firmware installed. Waiting for the watch to restart.")
        await DiagnosticLog.shared.record(
            category: "firmware",
            message: "the watch took the firmware and is restarting"
        )
        await pendingFirmwareUpdateStore.clear()
        discardDownloadedFirmware(matching: package)
    }

    /// The watch that took the firmware is back, so the restart it was waiting
    /// for has happened.
    ///
    /// Nothing else says so. The journal is cleared from disk the moment the
    /// transfer finishes, and the copy held here is what the screens read: left
    /// at `awaitingRestart` it offers Stop and Try Again for an update that is
    /// over, and the watch's own row goes on saying an update is waiting.
    func noteFirmwareUpdateFinished(on watch: ConnectedWatch) {
        guard firmware.journal?.watchID == watch.id,
              firmware.journal?.phase == .awaitingRestart else { return }
        firmware.journal = nil
        firmware.feedback = nil
    }

    /// The package on disk has done its job. Left there it keeps telling the
    /// reader that firmware is downloaded and waiting, on a watch that is at that
    /// moment restarting into it.
    func discardDownloadedFirmware(matching package: PBZFirmwarePackage) {
        guard let downloaded = firmware.downloaded,
              downloaded.versionTag == package.manifest.firmware.versionTag,
              downloaded.board == package.manifest.firmware.board else {
            return
        }
        try? FileManager.default.removeItem(at: downloaded.url)
        firmware.downloaded = nil
        Defaults[.downloadedFirmware] = nil
    }

    // The only case that runs unasked, which is the whole point of staging one.
    func resumePendingFirmwareUpdate(on connection: WatchConnection) async {
        let watch = connection.watch
        guard let package = try? await pendingFirmwareUpdateStore.package(),
              let journal = try? await pendingFirmwareUpdateStore.journal(),
              journal.watchID == watch.id,
              journal.board == watch.board,
              journal.packageSHA256 == package.sha256,
              journal.phase != .cancelled else { return }
        firmware.journal = journal
        guard journal.phase.mayStartUnattended else {
            firmware.feedback = .failure("The firmware update stopped part-way. Resume it when you are ready.")
            return
        }
        if package.manifest.firmware.type == "recovery" {
            firmware.requiresConfirmation = true
            firmware.feedback = .progress("Recovery firmware is ready. Confirm to continue.")
            return
        }
        do {
            firmware.feedback = .progress("Installing the firmware chosen for this watch…")
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware.feedback = .failure("Firmware update stopped safely: \(failureReason(for: error))")
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
        guard Defaults[.notifiedFirmwareVersions][watch.id.rawValue] != release.versionTag else {
            return
        }
        Defaults[.notifiedFirmwareVersions][watch.id.rawValue] = release.versionTag
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

    public func resumeFirmwareUpdate(watchID: WatchID? = nil) async {
        guard let package = try? await pendingFirmwareUpdateStore.package(),
              let journal = try? await pendingFirmwareUpdateStore.journal(),
              let connection = connection(for: watchID ?? journal.watchID),
              connection.isConnected else {
            firmware.feedback = .failure("Connect the watch to resume its firmware update.")
            return
        }
        do {
            try await performFirmwareUpdate(package, on: connection)
        } catch is CancellationError {
        } catch {
            firmware.feedback = .failure("Firmware update stopped safely: \(failureReason(for: error))")
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
