import PebbleProtocol
import SwiftUI

struct WatchDetailView: View {
    var model: AppModel
    var watchID: WatchID
    @Environment(\.dismiss) private var dismiss

    private var journal: FirmwareUpdateJournal? {
        guard let journal = model.firmware.journal, journal.watchID == watchID else {
            return nil
        }
        return journal
    }

    // A language reads best in itself, so the name is not translated.
    private var languageName: String? {
        guard let locale = model.connections.first(where: { $0.watch.id == watchID })?.watch.languageLocale,
              !locale.isEmpty else {
            return nil
        }
        return model.languagePacks(watchID: watchID).first { $0.locale == locale }?.localName ?? locale
    }

    var body: some View {
        WatchDetailContent(
            watch: WatchSummary(watchID: watchID, model: model),
            firmwareJournalPhase: journal?.phase,
            downloadedFirmwareVersion: model.firmware.downloaded?.versionTag,
            languageName: languageName,
            resetFeedback: model.watches.resetFeedback[watchID],
            connectionFeedback: model.connectionFailures[watchID].map { .failure($0.message) },
            connect: {
                guard let saved = model.watches.saved.first(where: { $0.id == watchID }) else { return }
                Task { await model.connect(to: saved) }
            },
            setAutomaticallyConnects: { enabled in
                Task { await model.setAutomaticallyConnects(enabled, watchID: watchID) }
            },
            disconnect: { Task { await model.disconnect(watchID: watchID) } },
            reset: { kind in Task { await model.resetWatch(kind, watchID: watchID) } },
            forget: {
                Task {
                    await model.forgetWatch(id: watchID)
                    dismiss()
                }
            },
            firmwareDestination: { FirmwareView(model: model, watchID: watchID) },
            languageDestination: { LanguageView(model: model, watchID: watchID) },
            settingsDestination: { WatchSettingsView(model: model, watchID: watchID) },
            diagnosticsDestination: { WatchDiagnosticsView(model: model, watchID: watchID) }
        )
    }
}

struct WatchDetailContent<
    FirmwareDestination: View,
    LanguageDestination: View,
    SettingsDestination: View,
    DiagnosticsDestination: View
>: View {
    var watch: WatchSummary
    var firmwareJournalPhase: FirmwareUpdatePhase?
    var downloadedFirmwareVersion: String?
    var languageName: String?
    var resetFeedback: FeatureFeedback?
    var connectionFeedback: FeatureFeedback?
    var connect: () -> Void
    var setAutomaticallyConnects: (Bool) -> Void
    var disconnect: () -> Void
    var reset: (ResetKind) -> Void
    var forget: () -> Void
    @ViewBuilder var firmwareDestination: () -> FirmwareDestination
    @ViewBuilder var languageDestination: () -> LanguageDestination
    @ViewBuilder var settingsDestination: () -> SettingsDestination
    @ViewBuilder var diagnosticsDestination: () -> DiagnosticsDestination

    // A version is a version in any language, so it is not translated.
    private var firmwareSummary: Text {
        if let firmwareJournalPhase {
            return firmwareJournalPhase == .transferring || firmwareJournalPhase == .installing
                ? Text("Installing…")
                : Text("Update waiting")
        }
        if watch.isRunningRecoveryFirmware {
            return Text("Recovery firmware")
        }
        if let downloadedFirmwareVersion {
            return Text("\(downloadedFirmwareVersion) ready")
        }
        guard let version = watch.firmwareVersion else {
            return Text("Unknown")
        }
        return Text(verbatim: version)
    }

    private var languageSummary: Text {
        guard let languageName else {
            return watch.isConnected ? Text("English") : Text("Unknown")
        }
        return Text(verbatim: languageName)
    }

    var body: some View {
        Form {
            if watch.isRunningRecoveryFirmware {
                Section {
                    NavigationLink {
                        RecoveryFirmwareGuide(
                            watchName: watch.name,
                            isConnected: watch.isConnected,
                            firmwareDestination: firmwareDestination
                        )
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Firmware Required")
                                    .font(.headline)
                                Text("This watch started its recovery firmware. It works again once PebbleOS is installed.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            Section {
                // First, and with the model as its summary, so the row still
                // says which watch this is without being opened — the one
                // thing the old section said at a glance.
                if WatchInformationContent.hasAnything(
                    model: watch.model,
                    serialNumber: watch.serialNumber,
                    hardwareRevision: watch.hardwareRevision,
                    firmwareVersion: watch.firmwareVersion
                ) {
                    NavigationLink {
                        WatchInformationContent(
                            model: watch.model,
                            serialNumber: watch.serialNumber,
                            hardwareRevision: watch.hardwareRevision,
                            firmwareVersion: watch.firmwareVersion
                        )
                    } label: {
                        LabeledContent("General Information") {
                            if let model = watch.model {
                                Text(model.displayName)
                            }
                        }
                    }
                }
                NavigationLink {
                    firmwareDestination()
                } label: {
                    LabeledContent("Firmware") { firmwareSummary }
                }
                NavigationLink {
                    languageDestination()
                } label: {
                    LabeledContent("Language") { languageSummary }
                }
                NavigationLink {
                    settingsDestination()
                } label: {
                    Text("Watch Settings")
                }
                NavigationLink {
                    diagnosticsDestination()
                } label: {
                    Text("Diagnostics")
                }
            }

            Section("Connection") {
                LabeledContent("Status") {
                    switch watch.phase {
                    case .connected:
                        Text("Connected")
                    case .reconnecting:
                        Text("Reconnecting…")
                    case .disconnected, nil:
                        Text("Not connected")
                    }
                }
                if watch.phase == nil, watch.isSaved {
                    Button("Connect", systemImage: "applewatch.radiowaves.left.and.right", action: connect)
                        .disabled(watch.isConnecting)
                }
                if watch.isSaved {
                    Toggle("Connect Automatically", isOn: Binding(
                        get: { watch.automaticallyConnects },
                        set: { setAutomaticallyConnects($0) }
                    ))
                }
                if watch.phase != nil {
                    Button("Disconnect", role: .destructive, action: disconnect)
                }
                FeedbackBanner(feedback: connectionFeedback)
            }

            Section {
                ConfirmingButton(
                    title: "Restart Watch",
                    systemImage: "arrow.clockwise",
                    question: "Restart \(watch.name)?",
                    explanation: "The watch disconnects while it restarts.",
                    confirmationTitle: "Restart Watch",
                    confirmationRole: nil
                ) {
                    reset(.restart)
                }
                .disabled(!watch.isConnected)
                ConfirmingButton(
                    title: "Restart into Recovery Firmware",
                    systemImage: "lifepreserver",
                    question: "Restart \(watch.name) into recovery firmware?",
                    explanation: "The watch restarts into recovery firmware, where only firmware updates are available.",
                    confirmationTitle: "Restart into Recovery Firmware",
                    confirmationRole: nil
                ) {
                    reset(.recoveryFirmware)
                }
                .disabled(!watch.isConnected)
                ConfirmingButton(
                    title: "Factory Reset",
                    systemImage: "trash",
                    role: .destructive,
                    question: "Erase \(watch.name)?",
                    explanation: "Every app, watchface, and setting stored on the watch is erased. This cannot be undone.",
                    confirmationTitle: "Erase Watch"
                ) {
                    reset(.factoryReset)
                }
                .disabled(!watch.isConnected)
                FeedbackBanner(feedback: resetFeedback)
            } header: {
                Text("Reset")
            } footer: {
                Text("The watch restarts without answering, so it disconnects immediately. A factory reset erases everything stored on the watch.")
            }
            Section {
                ConfirmingButton(
                    title: "Forget Watch",
                    role: .destructive,
                    question: "Forget \(watch.name)?",
                    explanation: "Automatic reconnection information for this Pebble will be removed.",
                    confirmationTitle: "Forget Watch",
                    action: forget
                )
            } footer: {
                #if os(macOS)
                Text("A watch that has been factory reset no longer knows this Mac, and cannot be added again while the old pairing is around. Forget it here, then open System Settings › Bluetooth and forget it there too.")
                #else
                Text("A watch that has been factory reset no longer knows this iPhone, and cannot be added again while the old pairing is around. Forget it here, then open Settings › Bluetooth, tap the ⓘ beside it and choose Forget This Device.")
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle(watch.name)
    }
}

#Preview("Connected") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.connectedSummary,
            firmwareJournalPhase: nil,
            downloadedFirmwareVersion: nil,
            languageName: "日本語",
            resetFeedback: nil,
            connectionFeedback: nil,
            connect: {},
            setAutomaticallyConnects: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}

#Preview("Away, update waiting") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.savedSummary,
            firmwareJournalPhase: .validated,
            downloadedFirmwareVersion: PreviewSamples.firmwareRelease.versionTag,
            languageName: nil,
            resetFeedback: nil,
            connectionFeedback: .failure("The watch does not expose the expected Pebble connection service."),
            connect: {},
            setAutomaticallyConnects: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}

#Preview("Recovery firmware") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.recoverySummary,
            firmwareJournalPhase: nil,
            downloadedFirmwareVersion: nil,
            languageName: nil,
            resetFeedback: .progress("The watch is erasing itself. It has forgotten this device, so it cannot reconnect until it is forgotten here too."),
            connectionFeedback: nil,
            connect: {},
            setAutomaticallyConnects: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}
