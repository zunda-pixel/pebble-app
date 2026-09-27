import PebbleProtocol
import SwiftUI

/// The screens the Settings rows on a watch's detail screen open.
enum WatchSettingsPage: Hashable {
    case appearance
    case backlight
    case quietTime
    case quickLaunch
    case music
    case health
}

struct WatchDetailView: View {
    var model: AppModel
    var watchID: WatchID
    @Environment(\.dismiss) private var dismiss
    /// Why Forget did not, for the screen the reader is still on.
    @State private var forgetFeedback: FeatureFeedback?

    // A language reads best in itself, so the name is not translated.
    private var languageName: String? {
        guard let locale = model.connections.first(where: { $0.watch.id == watchID })?.watch.languageLocale,
              !locale.isEmpty else {
            return nil
        }
        if let pack = model.languagePacks(watchID: watchID).first(where: { $0.locale == locale }) {
            return pack.localName
        }
        // The watch reports an identifier such as "ja_JP"; shown bare when no
        // pack in the catalogue names it, it read as a code, not a language.
        let language = Locale(identifier: locale)
        return language.localizedString(forIdentifier: locale) ?? locale
    }

    private func currentWatchSettings(board: WatchBoard?) -> [WatchSetting: Int] {
        Dictionary(
            uniqueKeysWithValues: WatchSetting.allCases.map { setting in
                // The brightness row shows the preset the watch would
                // report rather than the number last written, the way
                // `backlight_get_preset` derives it: turning the brightness
                // down by hand leaves the watch on "Custom", and this
                // screen has to say so instead of claiming a preset the
                // watch has left behind.
                guard setting == .backlightPreset else {
                    return (setting, model.watchSettingValue(setting))
                }
                return (
                    setting,
                    BacklightPreset.reported(by: { model.watchSettingValue($0) }, on: board)
                )
            }
        )
    }

    private func setWatchSetting(_ setting: WatchSetting, _ rawValue: Int) {
        Task { await model.setWatchSetting(setting, rawValue: rawValue) }
    }

    /// `board` is the connected watch's, or the remembered one while it is
    /// away. Nil for a watch neither knows, which hides the rows only some
    /// boards have.
    @ViewBuilder
    private func settingsPage(
        _ page: WatchSettingsPage,
        watchSettings: [WatchSetting: Int],
        board: WatchBoard?,
        isConnected: Bool
    ) -> some View {
        let feedback = model.watchSettings.feedback
        switch page {
        case .appearance:
            AppearanceSettingsContent(
                watchSettings: watchSettings,
                board: board,
                isConnected: isConnected,
                feedback: feedback,
                setWatchSetting: setWatchSetting
            )
        case .backlight:
            BacklightSettingsContent(
                watchSettings: watchSettings,
                board: board,
                feedback: feedback,
                setWatchSetting: setWatchSetting
            )
        case .quietTime:
            QuietTimeSettingsContent(
                watchSettings: watchSettings,
                feedback: feedback,
                setWatchSetting: setWatchSetting
            )
        case .quickLaunch:
            QuickLaunchSettingsContent(
                assignments: { model.quickLaunchAssignment(for: $0) },
                applications: model.applications.all,
                feedback: feedback,
                setAssignment: { button, assignment in
                    Task { await model.setQuickLaunch(button, to: assignment) }
                }
            )
        case .music:
            MusicWatchSettingsContent(
                watchSettings: watchSettings,
                board: board,
                feedback: feedback,
                setWatchSetting: setWatchSetting
            )
        case .health:
            HealthWatchSettingsContent(
                activitySettings: model.watchSettings.activity,
                heartRateSettings: model.watchSettings.heartRate,
                heartRateZones: model.watchSettings.heartRateZones,
                bloodOxygenSettings: model.watchSettings.bloodOxygen,
                board: board,
                feedback: feedback,
                setActivitySettings: { settings in
                    Task { await model.setActivitySettings(settings) }
                },
                setHeartRateSettings: { settings in
                    Task { await model.setHeartRateSettings(settings) }
                },
                setHeartRateZones: { preferences in
                    Task { await model.setHeartRateZones(preferences) }
                },
                setBloodOxygenSettings: { settings in
                    Task { await model.setBloodOxygenSettings(settings) }
                }
            )
        }
    }

    /// Only iOS forwards notifications to an accessory, and only to a watch
    /// the app has added.
    private func forwardingSection(isSaved: Bool) -> NotificationForwardingSection<ReplyTemplatesView>? {
        #if os(iOS)
        guard isSaved else { return nil }
        return NotificationForwardingSection(
            forwarding: model.notificationForwarding(watchID: watchID),
            allow: { Task { await model.requestNotificationForwarding(watchID: watchID) } },
            openSettings: { Task { await model.openNotificationForwardingSettings(watchID: watchID) } },
            replyTemplatesDestination: { ReplyTemplatesView(model: model) }
        )
        #else
        return nil
        #endif
    }

    var body: some View {
        let watch = WatchSummary(watchID: watchID, model: model)
        let watchSettings = currentWatchSettings(board: watch.board)
        WatchDetailContent(
            watch: watch,
            languageName: languageName,
            backlightSummary: BacklightSettingsContent.summary(of: watchSettings),
            quietTimeSummary: QuietTimeSettingsContent.summary(of: watchSettings),
            isReminderAppEnabled: model.timeline.isReminderAppEnabled,
            settingsFeedback: model.watchSettings.feedback,
            resetFeedback: model.watches.resetFeedback[watchID],
            forgetFeedback: forgetFeedback,
            connectionFeedback: model.connectionFailures[watchID].map { .failure($0.message) },
            forwardingSection: forwardingSection(isSaved: watch.isSaved),
            connect: {
                guard let saved = model.watches.saved.first(where: { $0.id == watchID }) else { return }
                Task { await model.connect(to: saved) }
            },
            setAutomaticallyConnects: { enabled in
                Task { await model.setAutomaticallyConnects(enabled, watchID: watchID) }
            },
            setReminderAppEnabled: { isOn in
                Task { await model.setReminderAppEnabled(isOn) }
            },
            disconnect: { Task { await model.disconnect(watchID: watchID) } },
            reset: { kind in Task { await model.resetWatch(kind, watchID: watchID) } },
            forget: {
                Task {
                    if await model.forgetWatch(id: watchID) {
                        dismiss()
                    } else {
                        forgetFeedback = model.watches.feedback
                    }
                }
            },
            firmwareDestination: { FirmwareView(model: model, watchID: watchID) },
            languageDestination: { LanguageView(model: model, watchID: watchID) },
            settingsDestination: { page in
                settingsPage(
                    page,
                    watchSettings: watchSettings,
                    board: watch.board,
                    isConnected: watch.isConnected
                )
            },
            diagnosticsDestination: { WatchDiagnosticsView(model: model, watchID: watchID) }
        )
        #if os(iOS)
        .task { await model.refreshNotificationForwarding(watchID: watchID) }
        #endif
    }
}

struct WatchDetailContent<
    FirmwareDestination: View,
    LanguageDestination: View,
    SettingsDestination: View,
    DiagnosticsDestination: View
>: View {
    var watch: WatchSummary
    var languageName: String?
    var backlightSummary: LocalizedStringKey
    var quietTimeSummary: LocalizedStringKey
    var isReminderAppEnabled: Bool
    var settingsFeedback: FeatureFeedback? = nil
    var resetFeedback: FeatureFeedback?
    var forgetFeedback: FeatureFeedback? = nil
    var connectionFeedback: FeatureFeedback?
    var forwardingSection: NotificationForwardingSection<ReplyTemplatesView>? = nil
    var connect: () -> Void
    var setAutomaticallyConnects: (Bool) -> Void
    var setReminderAppEnabled: (Bool) -> Void
    var disconnect: () -> Void
    var reset: (ResetKind) -> Void
    var forget: () -> Void
    @ViewBuilder var firmwareDestination: () -> FirmwareDestination
    @ViewBuilder var languageDestination: () -> LanguageDestination
    @ViewBuilder var settingsDestination: (WatchSettingsPage) -> SettingsDestination
    @ViewBuilder var diagnosticsDestination: () -> DiagnosticsDestination

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
                        LabeledContent("About") {
                            if let model = watch.model {
                                Text(model.displayName)
                            }
                        }
                    }
                }
                NavigationLink {
                    firmwareDestination()
                } label: {
                    Text("Software Update")
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

            if let forwardingSection {
                forwardingSection
            }

            Section {
                // Above the rows rather than on the screens they open, so the
                // reader knows before changing anything that it waits for the
                // watch.
                if !watch.isConnected {
                    Label("Changes are kept and written when the watch connects.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                // Not only on the screens these open: a write that fails after
                // the reader has come back would answer where nobody looks.
                FeedbackBanner(feedback: settingsFeedback)
                NavigationLink {
                    settingsDestination(.appearance)
                } label: {
                    Text("Appearance")
                }
                NavigationLink {
                    languageDestination()
                } label: {
                    LabeledContent("Language") { languageSummary }
                }
                NavigationLink {
                    settingsDestination(.backlight)
                } label: {
                    LabeledContent("Backlight") { Text(backlightSummary) }
                }
                NavigationLink {
                    settingsDestination(.quietTime)
                } label: {
                    LabeledContent("Focus") { Text(quietTimeSummary) }
                }
                NavigationLink {
                    settingsDestination(.quickLaunch)
                } label: {
                    Text("Quick Launch")
                }
                NavigationLink {
                    settingsDestination(.music)
                } label: {
                    Text("Music")
                }
                NavigationLink {
                    settingsDestination(.health)
                } label: {
                    Text("Health")
                }
            } header: {
                Text("Settings")
            } footer: {
                Text("These are the watch's own settings. They are written again whenever it connects, so this is the copy that wins.")
            }

            Section {
                Toggle("Reminders App", isOn: Binding(
                    get: { isReminderAppEnabled },
                    set: { isOn in setReminderAppEnabled(isOn) }
                ))
            } footer: {
                Text("Turns the watch's own Reminders app on, which is where the reminders added on the Timeline screen appear.")
            }

            Section {
                NavigationLink {
                    diagnosticsDestination()
                } label: {
                    Text("Diagnostics")
                }
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
                FeedbackBanner(feedback: forgetFeedback)
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
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
    }
}

#Preview("Connected") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.connectedSummary,
            languageName: "日本語",
            backlightSummary: BacklightSettingsContent.summary(of: [.backlight: 1]),
            quietTimeSummary: QuietTimeSettingsContent.summary(of: [.quietTimeWeekdayScheduleEnabled: 1]),
            isReminderAppEnabled: true,
            resetFeedback: nil,
            connectionFeedback: nil,
            connect: {},
            setAutomaticallyConnects: { _ in },
            setReminderAppEnabled: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { _ in EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}

#Preview("Away, update waiting") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.savedSummary,
            languageName: nil,
            backlightSummary: BacklightSettingsContent.summary(of: [:]),
            quietTimeSummary: QuietTimeSettingsContent.summary(of: [:]),
            isReminderAppEnabled: false,
            settingsFeedback: .failure("Pebble 5209 did not accept the setting."),
            resetFeedback: nil,
            connectionFeedback: .failure("The watch does not expose the expected Pebble connection service."),
            connect: {},
            setAutomaticallyConnects: { _ in },
            setReminderAppEnabled: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { _ in EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}

#Preview("Recovery firmware") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.recoverySummary,
            languageName: nil,
            backlightSummary: BacklightSettingsContent.summary(of: [:]),
            quietTimeSummary: QuietTimeSettingsContent.summary(of: [:]),
            isReminderAppEnabled: false,
            resetFeedback: .progress("The watch is erasing itself. It has forgotten this device, so it cannot reconnect until it is forgotten here too."),
            connectionFeedback: nil,
            connect: {},
            setAutomaticallyConnects: { _ in },
            setReminderAppEnabled: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { _ in EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}

#Preview("Could not be forgotten") {
    NavigationStack {
        WatchDetailContent(
            watch: PreviewSamples.savedSummary,
            languageName: nil,
            backlightSummary: BacklightSettingsContent.summary(of: [.backlight: 0]),
            quietTimeSummary: QuietTimeSettingsContent.summary(of: [.quietTimeManual: 1]),
            isReminderAppEnabled: true,
            resetFeedback: nil,
            forgetFeedback: .failure("The watch could not be forgotten."),
            connectionFeedback: nil,
            connect: {},
            setAutomaticallyConnects: { _ in },
            setReminderAppEnabled: { _ in },
            disconnect: {},
            reset: { _ in },
            forget: {},
            firmwareDestination: { EmptyView() },
            languageDestination: { EmptyView() },
            settingsDestination: { _ in EmptyView() },
            diagnosticsDestination: { EmptyView() }
        )
    }
}
