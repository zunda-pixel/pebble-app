import API
import Defaults
public import Foundation
import SwiftUI

/// Choosing, downloading and transferring watch firmware.
extension AppModel {
    /// Validates a firmware package and either installs it right away or keeps
    /// it for the watch's next connection.
    ///
    /// Staging matters for a watch running its recovery firmware: it stays
    /// connected for only a few seconds at a time, which is not long enough to
    /// pick a file, so the file is chosen first and the transfer starts as soon
    /// as the watch appears.
    public func installFirmware(from url: URL, deviceID: String? = nil) async {
        let connection = connection(for: deviceID).flatMap { $0.isConnected ? $0 : nil }
        let target: (id: String, board: PebbleWatchBoard, firmwareVersion: String?, slot: Int?)
        if let connection, let board = connection.device.board {
            let device = connection.device
            target = (device.id, board, device.firmwareVersion, device.firmwareUpdateSlot)
        } else if let saved = savedWatch(for: deviceID), let board = saved.board {
            // The slot is only known while connected; without it any manifest
            // for this board is accepted and the watch has the last word.
            target = (saved.id, board, saved.firmwareVersion, nil)
        } else {
            firmwareUpdateStatusMessage =
                "Connect the target Pebble once so its board is known, then choose firmware."
            return
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            firmwareUpdateStatusMessage = "Validating firmware…"
            let package = try await Task.detached { [board = target.board, slot = target.slot] in
                try PBZFirmwareImporter.load(from: url, board: board, targetSlot: slot)
            }.value
            try package.validateIntegrity()
            let journal = FirmwareUpdateJournal(
                deviceID: target.id,
                hardwareRevision: target.board.rawValue,
                previousVersion: target.firmwareVersion,
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
            guard let connection else {
                firmwareUpdateStatusMessage =
                    "Firmware ready. It installs as soon as the watch connects."
                return
            }
            try await performFirmwareUpdate(package, on: connection)
        } catch {
            firmwareUpdateStatusMessage = "Firmware update stopped safely: \(error.localizedDescription)"
        }
    }

    /// Looks up the newest firmware published for a watch's board.
    public func checkForFirmwareUpdate(deviceID: String? = nil) async {
        guard let board = board(for: deviceID) else {
            firmwareUpdateStatusMessage =
                "Connect the target Pebble once so its board is known, then check for firmware."
            return
        }
        do {
            firmwareUpdateStatusMessage = "Looking for published firmware…"
            let release = try await firmwareCatalog.latestRelease(for: board)
            availableFirmwareRelease = release
            firmwareUpdateStatusMessage = "PebbleOS \(release.versionTag) is available."
        } catch {
            availableFirmwareRelease = nil
            firmwareUpdateStatusMessage = "Published firmware could not be checked right now."
        }
    }

    /// Fetches the published firmware and keeps it. Installing it is a
    /// separate step: the download only needs the network, the install needs
    /// the watch, and a watch in recovery firmware is not around for long.
    public func downloadAvailableFirmware(deviceID: String? = nil) async {
        guard let release = availableFirmwareRelease else {
            await checkForFirmwareUpdate(deviceID: deviceID)
            guard availableFirmwareRelease != nil else { return }
            await downloadAvailableFirmware(deviceID: deviceID)
            return
        }
        do {
            firmwareUpdateStatusMessage = "Downloading PebbleOS \(release.versionTag)…"
            let firmware = try await firmwareCatalog.download(release)
            downloadedFirmware = firmware
            Defaults[.downloadedFirmware] = firmware
            firmwareUpdateStatusMessage = "PebbleOS \(firmware.versionTag) is ready to install."
        } catch {
            firmwareUpdateStatusMessage = "Firmware could not be downloaded right now."
        }
    }

    /// Installs what was downloaded earlier, which is the same path a chosen
    /// file takes.
    public func installDownloadedFirmware(deviceID: String? = nil) async {
        guard let firmware = downloadedFirmware else {
            firmwareUpdateStatusMessage = "Download the firmware first."
            return
        }
        await installFirmware(from: firmware.url, deviceID: deviceID)
    }

    /// Picks up a download from an earlier run, unless the file is gone.
    func loadDownloadedFirmware() {
        guard let firmware = Defaults[.downloadedFirmware] else { return }
        guard FileManager.default.fileExists(atPath: firmware.url.path(percentEncoded: false)) else {
            Defaults[.downloadedFirmware] = nil
            return
        }
        downloadedFirmware = firmware
    }

    /// The board of the watch a firmware action targets, connected or not.
    func board(for deviceID: String?) -> PebbleWatchBoard? {
        if let connection = connection(for: deviceID), let board = connection.device.board {
            return board
        }
        return savedWatch(for: deviceID)?.board
    }

    /// The saved watch a firmware action targets when none is connected.
    func savedWatch(for deviceID: String?) -> SavedPebbleWatch? {
        guard let deviceID else {
            return savedWatches.count == 1 ? savedWatches.first : nil
        }
        return savedWatches.first { $0.id == deviceID }
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

    func performFirmwareUpdate(
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
        // One transfer at a time. Two can be asked for at once — a staged
        // update starting itself the moment the watch reconnects, while the
        // reader taps Install — and the second would take over the task and
        // the transfer flags the first is using, leaving that one waiting on a
        // reply nobody is holding. The claim is made in the same step as the
        // check, with nothing awaited in between, so only one caller gets past.
        guard firmwareUpdateTask == nil else {
            firmwareUpdateStatusMessage = "This firmware is already being transferred."
            return
        }
        firmwareUpdateStatusMessage = "Transferring verified firmware…"
        firmwareTransferDeviceID = connection.device.id
        connection.beginTransfer()
        let client = connection.client
        let task = Task { try await client.installFirmware(package) }
        firmwareUpdateTask = task
        defer {
            firmwareUpdateTask = nil
            firmwareTransferDeviceID = nil
            connection.endTransfer()
        }
        do {
            try await task.value
        } catch {
            // Record the failure, so the next connection offers the update
            // again instead of silently starting the whole transfer over.
            // A cancelled journal already says what happened.
            let stopped = try? await pendingFirmwareUpdateLibrary.journal()
            if stopped?.phase == .transferring {
                try? await pendingFirmwareUpdateLibrary.updatePhase(.failed)
                firmwareUpdateJournal = try? await pendingFirmwareUpdateLibrary.journal()
            }
            throw error
        }
        try await pendingFirmwareUpdateLibrary.updatePhase(.awaitingRestart)
        firmwareUpdateJournal = try await pendingFirmwareUpdateLibrary.journal()
        firmwareUpdateStatusMessage = "Firmware installed. Waiting for the watch to restart."
        await pendingFirmwareUpdateLibrary.clear()
    }

    /// Starts an update that was accepted while the watch was away, as soon as
    /// it turns up. Only that case runs unasked: it is the whole point of
    /// staging one, and a watch in recovery firmware stays connected for too
    /// short a time to be caught by hand. An update that already ran and
    /// stopped waits to be started again.
    func resumePendingFirmwareUpdate(on connection: WatchConnection) async {
        let device = connection.device
        guard let package = try? await pendingFirmwareUpdateLibrary.package(),
              let journal = try? await pendingFirmwareUpdateLibrary.journal(),
              journal.deviceID == device.id,
              journal.hardwareRevision == device.board?.rawValue,
              journal.packageSHA256 == package.sha256,
              journal.phase != .cancelled else { return }
        firmwareUpdateJournal = journal
        guard journal.phase.mayStartUnattended else {
            firmwareUpdateStatusMessage = "The firmware update stopped part-way. Resume it when you are ready."
            return
        }
        if package.manifest.firmware.type == "recovery" {
            firmwareRequiresConfirmation = true
            firmwareUpdateStatusMessage = "Recovery firmware is ready. Confirm to continue."
            return
        }
        do {
            firmwareUpdateStatusMessage = "Installing the firmware chosen for this watch…"
            try await performFirmwareUpdate(package, on: connection)
        } catch {
            firmwareUpdateStatusMessage = "Firmware update stopped safely: \(error.localizedDescription)"
        }
    }

    /// Starts an update that stopped part-way, at the reader's request.
    public func resumeFirmwareUpdate(deviceID: String? = nil) async {
        guard let package = try? await pendingFirmwareUpdateLibrary.package(),
              let journal = try? await pendingFirmwareUpdateLibrary.journal(),
              let connection = connection(for: deviceID ?? journal.deviceID),
              connection.isConnected else {
            firmwareUpdateStatusMessage = "Connect the watch to resume its firmware update."
            return
        }
        do {
            try await performFirmwareUpdate(package, on: connection)
        } catch {
            firmwareUpdateStatusMessage = "Firmware update stopped safely: \(error.localizedDescription)"
        }
    }
}
