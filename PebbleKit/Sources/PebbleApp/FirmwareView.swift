import SwiftUI
import PebbleProtocol
import UniformTypeIdentifiers

struct FirmwareView: View {
    var model: AppModel
    var watchID: WatchID

    var body: some View {
        let summary = WatchSummary(watchID: watchID, model: model)
        let state = model.firmware[watchID]
        FirmwareContent(
            installedVersion: summary.firmwareVersion,
            isConnected: summary.isConnected,
            isRunningRecoveryFirmware: summary.isRunningRecoveryFirmware,
            availableRelease: state.availableRelease.flatMap { $0.board == summary.board ? $0 : nil },
            downloadedFirmware: model.downloadedFirmware(for: watchID),
            journal: state.journal,
            progress: state.journal == nil ? nil : model.firmwareTransferProgress(on: watchID),
            feedback: state.feedback,
            requiresConfirmation: state.requiresConfirmation,
            checkForUpdates: { await model.checkForFirmwareUpdate(watchID: watchID) },
            download: { Task { await model.downloadAvailableFirmware(watchID: watchID) } },
            installDownloaded: { Task { await model.installDownloadedFirmware(watchID: watchID) } },
            installFile: { url in Task { await model.installFirmware(from: url, watchID: watchID) } },
            confirmRecovery: { Task { await model.confirmRecoveryFirmwareUpdate(watchID: watchID) } },
            resume: { Task { await model.resumeFirmwareUpdate(watchID: watchID) } },
            cancel: { Task { await model.cancelFirmwareUpdate(watchID: watchID) } },
            discard: { Task { await model.discardPendingFirmwareUpdate(watchID: watchID) } }
        )
        // Once a launch: the list is megabytes, and pulling down asks again.
        .task {
            guard model.firmware[watchID].availableRelease == nil else { return }
            await model.checkForFirmwareUpdate(watchID: watchID)
        }
    }
}

struct FirmwareContent: View {
    var installedVersion: String?
    var isConnected: Bool
    var isRunningRecoveryFirmware: Bool
    var availableRelease: PebbleOSFirmwareRelease?
    var downloadedFirmware: DownloadedFirmware?
    var journal: FirmwareUpdateJournal?
    var progress: PutBytesTransferProgress?
    var feedback: FeatureFeedback?
    var requiresConfirmation: Bool
    var checkForUpdates: () async -> Void
    var download: () -> Void
    var installDownloaded: () -> Void
    var installFile: (URL) -> Void
    var confirmRecovery: () -> Void
    var resume: () -> Void
    var cancel: () -> Void
    var discard: () -> Void

    @State private var isChoosingFile = false

    var body: some View {
        Form {
            Section {
                if let status {
                    FirmwareStatusRow(status: status)
                }
                if let progress, progress.totalBytes > 0 {
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
                FeedbackBanner(feedback: feedback)
            }

            Section {
                if let availableRelease {
                    LabeledContent("Published", value: availableRelease.versionTag)
                    if downloadedFirmware?.versionTag != availableRelease.versionTag {
                        Button("Download PebbleOS \(availableRelease.versionTag)", systemImage: "arrow.down.circle", action: download)
                    }
                }
                if let downloadedFirmware {
                    LabeledContent("Downloaded", value: downloadedFirmware.versionTag)
                    Button("Install PebbleOS \(downloadedFirmware.versionTag)", systemImage: "arrow.down.app", action: installDownloaded)
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
                    // Recovery firmware leaves the watch unusable until the transfer finishes.
                    if requiresConfirmation {
                        ConfirmingButton(
                            title: "Start the Recovery Install",
                            role: .destructive,
                            question: "Install recovery firmware?",
                            explanation: "The watch cannot be used until this finishes. Keep it nearby and connected.",
                            confirmationTitle: "Install",
                            action: confirmRecovery
                        )
                    }
                    if !journal.phase.mayStartUnattended {
                        Button("Try Again", systemImage: "arrow.clockwise", action: resume)
                            .disabled(!isConnected)
                    }
                    Button("Stop", role: .destructive, action: cancel)
                    ConfirmingButton(
                        title: "Forget This Update",
                        role: .destructive,
                        question: "Forget this update?",
                        explanation: "The package is removed, so this update cannot be picked up again. The watch keeps the firmware it is running.",
                        confirmationTitle: "Forget",
                        action: discard
                    )
                } header: {
                    Text("This Update")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Software Update"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Awaited, so the indicator stays up until the catalogue has answered.
        .refreshable { await checkForUpdates() }
        #if os(macOS)
        // A Mac list is not pulled down, so it keeps a button to ask with.
        .toolbar {
            Button("Check for Updates", systemImage: "arrow.clockwise") {
                Task { await checkForUpdates() }
            }
        }
        #endif
        // Any file, not only `.pebbleFirmware`: a `.pbz` that iOS has filed under
        // another type — saved by another app, or given no extension on the
        // way down — was greyed out and could not be chosen at all. The package
        // is checked as firmware before anything is sent.
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.pebbleFirmware, .data]) { result in
            guard case .success(let url) = result else { return }
            installFile(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let firmwareURL = urls.first(where: { $0.pathExtension.lowercased() == "pbz" }) else {
                return false
            }
            installFile(firmwareURL)
            return true
        }
    }

    // An install under way beats one that stopped, which beats a watch that
    // cannot run the newest firmware.
    /// Nil until the catalogue has answered for a watch whose version is
    /// known: that version is on the General Information screen already.
    private var status: FirmwareStatus? {
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
        if isRunningRecoveryFirmware {
            return FirmwareStatus(
                title: "Running recovery firmware",
                detail: "The watch works again once firmware is installed.",
                systemImage: "lifepreserver.fill",
                tint: .orange
            )
        }
        if let downloadedFirmware {
            return FirmwareStatus(
                title: "PebbleOS \(downloadedFirmware.versionTag) is downloaded",
                detail: isConnected
                    ? "Install it whenever you like."
                    : "Connect the watch to install it.",
                systemImage: "arrow.down.app.fill",
                tint: .accentColor
            )
        }
        if let availableRelease,
           installedVersion.map({ PebbleOSFirmwareCatalog.isVersion(availableRelease.versionTag, newerThan: $0) }) ?? true {
            return FirmwareStatus(
                title: "PebbleOS \(availableRelease.versionTag) is published",
                detail: "Download it, then install it.",
                systemImage: "arrow.down.circle",
                tint: .accentColor
            )
        }
        if availableRelease != nil, installedVersion != nil {
            return FirmwareStatus(
                title: "PebbleOS is up to date",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }
        if installedVersion != nil {
            return nil
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
    var detail: LocalizedStringKey? = nil
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
                if let detail = status.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Up to date") {
    NavigationStack {
        FirmwareContent(
            installedVersion: PreviewSamples.firmwareRelease.versionTag,
            isConnected: true,
            isRunningRecoveryFirmware: false,
            availableRelease: PreviewSamples.firmwareRelease,
            downloadedFirmware: nil,
            journal: nil,
            progress: nil,
            feedback: nil,
            requiresConfirmation: false,
            checkForUpdates: {},
            download: {},
            installDownloaded: {},
            installFile: { _ in },
            confirmRecovery: {},
            resume: {},
            cancel: {},
            discard: {}
        )
    }
}

#Preview("Transferring") {
    NavigationStack {
        FirmwareContent(
            installedVersion: "v4.36.2",
            isConnected: true,
            isRunningRecoveryFirmware: false,
            availableRelease: PreviewSamples.firmwareRelease,
            downloadedFirmware: PreviewSamples.downloadedFirmware,
            journal: PreviewSamples.firmwareJournal(phase: .transferring),
            progress: PreviewSamples.transferProgress,
            feedback: .progress("Sending PebbleOS v4.37.0 to Pebble 5209."),
            requiresConfirmation: false,
            checkForUpdates: {},
            download: {},
            installDownloaded: {},
            installFile: { _ in },
            confirmRecovery: {},
            resume: {},
            cancel: {},
            discard: {}
        )
    }
}

#Preview("Stopped, watch away") {
    NavigationStack {
        FirmwareContent(
            installedVersion: "v4.36.2",
            isConnected: false,
            isRunningRecoveryFirmware: false,
            availableRelease: PreviewSamples.firmwareRelease,
            downloadedFirmware: PreviewSamples.downloadedFirmware,
            journal: PreviewSamples.firmwareJournal(phase: .failed),
            progress: nil,
            feedback: .failure("The transfer stopped."),
            requiresConfirmation: false,
            checkForUpdates: {},
            download: {},
            installDownloaded: {},
            installFile: { _ in },
            confirmRecovery: {},
            resume: {},
            cancel: {},
            discard: {}
        )
    }
}

#Preview("Recovery firmware") {
    NavigationStack {
        FirmwareContent(
            installedVersion: "v4.36.2",
            isConnected: true,
            isRunningRecoveryFirmware: true,
            availableRelease: nil,
            downloadedFirmware: PreviewSamples.downloadedFirmware,
            journal: PreviewSamples.firmwareJournal(phase: .validated),
            progress: nil,
            feedback: nil,
            requiresConfirmation: true,
            checkForUpdates: {},
            download: {},
            installDownloaded: {},
            installFile: { _ in },
            confirmRecovery: {},
            resume: {},
            cancel: {},
            discard: {}
        )
    }
}
