import SwiftUI
import API

/// Everything about one watch's firmware, on its own screen: what it runs now,
/// what PebbleOS publishes for it, and how far an install has got.
struct FirmwareView: View {
    var model: AppModel
    var watchID: String
    @State private var isChoosingFile = false

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var savedWatch: SavedPebbleWatch? {
        model.savedWatches.first { $0.id == watchID }
    }

    private var isConnected: Bool {
        connection?.isConnected == true
    }

    /// The update this watch has going, if the one on record is its own.
    private var journal: FirmwareUpdateJournal? {
        guard let journal = model.firmwareUpdateJournal, journal.deviceID == watchID else {
            return nil
        }
        return journal
    }

    private var installedVersion: String? {
        connection?.device.firmwareVersion ?? savedWatch?.firmwareVersion
    }

    var body: some View {
        Form {
            Section {
                FirmwareStatusRow(status: status)
                if let progress = model.firmwareUpdateProgress,
                   journal != nil,
                   progress.totalBytes > 0 {
                    ProgressView(
                        value: Double(progress.bytesSent),
                        total: Double(progress.totalBytes)
                    )
                    Text(
                        "\(Double(progress.bytesSent) / 1_048_576, format: .number.precision(.fractionLength(1))) of \(Double(progress.totalBytes) / 1_048_576, format: .number.precision(.fractionLength(1))) MB sent"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let message = model.firmwareUpdateStatusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("On the Watch") {
                LabeledContent("Version", value: installedVersion ?? "—")
                if let board = connection?.device.board ?? savedWatch?.board {
                    LabeledContent("Board", value: board.rawValue)
                }
                if let slot = connection?.device.runningFirmwareSlot {
                    LabeledContent("Running Slot", value: slot, format: .number)
                }
            }

            Section {
                Button("Check for Updates", systemImage: "arrow.clockwise") {
                    Task { await model.checkForFirmwareUpdate(deviceID: watchID) }
                }
                if let release = model.availableFirmwareRelease {
                    LabeledContent("Published", value: release.versionTag)
                    if model.downloadedFirmware?.versionTag != release.versionTag {
                        Button("Download PebbleOS \(release.versionTag)", systemImage: "arrow.down.circle") {
                            Task { await model.downloadAvailableFirmware(deviceID: watchID) }
                        }
                    }
                }
                if let downloaded = model.downloadedFirmware {
                    LabeledContent("Downloaded", value: downloaded.versionTag)
                    Button("Install PebbleOS \(downloaded.versionTag)", systemImage: "arrow.down.app") {
                        Task { await model.installDownloadedFirmware(deviceID: watchID) }
                    }
                }
            } header: {
                Text("PebbleOS")
            } footer: {
                Text("Downloading only needs the network, so it works with the watch away. Installing needs the watch, and starts as soon as it connects.")
            }

            Section {
                Button("Install from a File…", systemImage: "folder") {
                    isChoosingFile = true
                }
            } footer: {
                Text("A PBZ package built for this watch's board.")
            }

            if let journal {
                Section {
                    LabeledContent("State") { Text(journal.phase.title) }
                    if let targetVersion = journal.targetVersion {
                        LabeledContent("Installing", value: targetVersion)
                    }
                    if let previousVersion = journal.previousVersion {
                        LabeledContent("Replacing", value: previousVersion)
                    }
                    // Recovery firmware leaves the watch unusable until the
                    // transfer finishes, so it is never started unasked.
                    if model.firmwareRequiresConfirmation {
                        ConfirmingButton(
                            title: "Start the Recovery Install",
                            role: .destructive,
                            question: "Install recovery firmware?",
                            explanation: "The watch cannot be used until this finishes. Keep it nearby and connected.",
                            confirmationTitle: "Install"
                        ) {
                            Task { await model.confirmRecoveryFirmwareUpdate() }
                        }
                    }
                    if !journal.phase.mayStartUnattended {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            Task { await model.resumeFirmwareUpdate(deviceID: watchID) }
                        }
                        .disabled(!isConnected)
                    }
                    Button("Stop", role: .destructive) {
                        Task { await model.cancelFirmwareUpdate() }
                    }
                    ConfirmingButton(
                        title: "Forget This Update",
                        role: .destructive,
                        question: "Forget this update?",
                        explanation: "The package is removed, so this update cannot be picked up again. The watch keeps the firmware it is running.",
                        confirmationTitle: "Forget"
                    ) {
                        Task { await model.discardPendingFirmwareUpdate() }
                    }
                } header: {
                    Text("This Update")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Firmware")
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.pebbleFirmware]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.installFirmware(from: url, deviceID: watchID) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let firmwareURL = urls.first(where: { $0.pathExtension.lowercased() == "pbz" }) else {
                return false
            }
            Task { await model.installFirmware(from: firmwareURL, deviceID: watchID) }
            return true
        }
    }

    /// What the reader most needs to know, picked from the state that matters
    /// most: an install under way beats one that stopped, which beats a watch
    /// that cannot run anything else, which beats an update simply being there.
    private var status: FirmwareStatus {
        if let journal, journal.phase == .transferring || journal.phase == .installing {
            return FirmwareStatus(
                title: journal.targetVersion.map { "Installing PebbleOS \($0)" } ?? "Installing firmware",
                detail: "Keep the watch nearby until this finishes.",
                systemImage: "arrow.down.circle.fill",
                tint: .accentColor
            )
        }
        if let journal, journal.phase == .failed {
            return FirmwareStatus(
                title: "The install stopped",
                detail: isConnected
                    ? "Nothing was lost. Try again when you are ready."
                    : "Nothing was lost. Connect the watch to try again.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }
        if let journal, journal.phase.mayStartUnattended {
            return FirmwareStatus(
                title: journal.targetVersion.map { "PebbleOS \($0) is waiting" } ?? "An update is waiting",
                detail: "It installs as soon as this watch connects.",
                systemImage: "clock.fill",
                tint: .orange
            )
        }
        if connection?.device.isRunningRecoveryFirmware == true {
            return FirmwareStatus(
                title: "Running recovery firmware",
                detail: "The watch works again once firmware is installed.",
                systemImage: "lifepreserver.fill",
                tint: .orange
            )
        }
        if let downloaded = model.downloadedFirmware {
            return FirmwareStatus(
                title: "PebbleOS \(downloaded.versionTag) is downloaded",
                detail: isConnected
                    ? "Install it whenever you like."
                    : "Connect the watch to install it.",
                systemImage: "arrow.down.app.fill",
                tint: .accentColor
            )
        }
        if let release = model.availableFirmwareRelease, release.versionTag != installedVersion {
            return FirmwareStatus(
                title: "PebbleOS \(release.versionTag) is published",
                detail: "Download it, then install it.",
                systemImage: "arrow.down.circle",
                tint: .accentColor
            )
        }
        if let installedVersion {
            return FirmwareStatus(
                title: "PebbleOS \(installedVersion)",
                detail: "Check for updates to see what is published.",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }
        return FirmwareStatus(
            title: "Firmware unknown",
            detail: "Connect the watch to read the version it runs.",
            systemImage: "questionmark.circle",
            tint: .secondary
        )
    }
}

private struct FirmwareStatus {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var systemImage: String
    var tint: Color
}

private struct FirmwareStatusRow: View {
    var status: FirmwareStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.systemImage)
                .font(.title2)
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.headline)
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
