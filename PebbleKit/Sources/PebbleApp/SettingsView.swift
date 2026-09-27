import Defaults
public import SwiftUI
import PebbleProtocol

public struct SettingsRootView: View {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            SettingsView(model: model)
        }
        .task { await model.start() }
    }
}

struct SettingsView: View {
    var model: AppModel

    var body: some View {
        SettingsContent(
            weatherPlaceNames: model.weather.places.map(\.name),
            areCompanionNotificationsEnabled: model.notifications.companionEnabled,
            diagnosticReportURL: model.diagnostics.reportURL,
            diagnosticsFeedback: model.diagnostics.feedback[.report],
            voiceTranscription: model.voiceTranscriptionReadiness,
            voiceLanguages: model.voiceSupportedLanguages,
            phoneAlertsFeedback: model.phoneAlertsFeedback,
            setNotifyWhenFullyCharged: { enabled in
                Task { await model.setNotifyWhenFullyCharged(enabled) }
            },
            setNotifyAboutFirmwareUpdates: { enabled in
                Task { await model.setNotifyAboutFirmwareUpdates(enabled) }
            },
            setVoiceTranscriptionEnabled: { enabled in
                Task { await model.setVoiceTranscriptionEnabled(enabled) }
            },
            setVoiceSpokenLanguage: { identifier in
                Task { await model.setVoiceSpokenLanguage(identifier) }
            },
            prepareDiagnosticReport: { Task { await model.prepareDiagnosticReport() } },
            weatherDestination: { WeatherView(model: model) },
            notificationSettingsDestination: {
                NotificationSettingsContent(
                    areCompanionNotificationsEnabled: model.notifications.companionEnabled,
                    notificationPreferences: model.notifications.preferences,
                    applications: model.applications.all,
                    notificationSourceAppCount: model.notifications.sourceApps.count,
                    feedback: model.notifications.settingsFeedback,
                    setCompanionNotificationsEnabled: { model.setCompanionNotificationsEnabled($0) },
                    setQuietHours: { enabled, start, end in
                        Task { await model.setQuietHours(enabled: enabled, start: start, end: end) }
                    },
                    setNotificationsEnabled: { enabled, applicationID in
                        Task { await model.setNotificationsEnabled(enabled, applicationID: applicationID) }
                    },
                    phoneAppsDestination: { NotificationAppsView(model: model) }
                )
            }
        )
        // iOS can take the recognizer's model back, so what is on the phone is
        // read again each time the screen appears rather than remembered.
        .task { await model.refreshVoiceTranscriptionReadiness() }
    }
}

struct SettingsContent<WeatherDestination: View, NotificationSettingsDestination: View>: View {
    var weatherPlaceNames: [String]
    var areCompanionNotificationsEnabled: Bool
    var diagnosticReportURL: URL?
    /// The answer to asking for a diagnostic report, which is asked for here.
    var diagnosticsFeedback: FeatureFeedback?
    var voiceTranscription: VoiceTranscriptionReadiness
    /// The languages the recognizer can be asked for. Empty hides the picker —
    /// a phone that has not answered yet, or cannot at all, offers no choice.
    var voiceLanguages: [String] = []
    var phoneAlertsFeedback: FeatureFeedback?
    var setNotifyWhenFullyCharged: (Bool) -> Void = { _ in }
    var setNotifyAboutFirmwareUpdates: (Bool) -> Void = { _ in }
    var setVoiceTranscriptionEnabled: (Bool) -> Void
    var setVoiceSpokenLanguage: (String?) -> Void = { _ in }
    var prepareDiagnosticReport: () -> Void
    @ViewBuilder var weatherDestination: () -> WeatherDestination
    @ViewBuilder var notificationSettingsDestination: () -> NotificationSettingsDestination

    @State private var permissions = PhonePermissions()
    @Environment(\.scenePhase) private var scenePhase
    // Read through `@Default` rather than carried in as a parameter, so the
    // switch follows the stored value even when the model turns it back off —
    // a refused permission does exactly that.
    @Default(.notifyWhenFullyCharged) private var notifyWhenFullyCharged
    @Default(.notifyAboutFirmwareUpdates) private var notifyAboutFirmwareUpdates
    @Default(.voiceSpokenLanguage) private var spokenLanguage

    /// Named in the reader's own language and sorted the way they read, so 日本語
    /// is where a Japanese reader looks for it. The identifier the picker keeps
    /// is the locale's, untranslated.
    private var sortedVoiceLanguages: [(identifier: String, name: String)] {
        voiceLanguages
            .map { identifier in
                (identifier, Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private var voiceTranscriptionSummary: Text {
        switch voiceTranscription {
        case .unsupported: Text("Not Available in This Language")
        case .turnedOff: Text("Off")
        case .needsInstalling: Text("Not Downloaded")
        case .installing: Text("Downloading…")
        case .ready: Text("Ready")
        }
    }

    private var weatherSummary: Text {
        switch weatherPlaceNames.count {
        case 0: Text("Off")
        case 1: Text(verbatim: weatherPlaceNames[0])
        case let count: Text("\(count) places")
        }
    }

    var body: some View {
        Form {
            NavigationLink {
                notificationSettingsDestination()
            } label: {
                LabeledContent("Notifications") {
                    // Said here because it is the one thing on that screen
                    // worth knowing without opening it: nothing a watch
                    // app raises will arrive.
                    if !areCompanionNotificationsEnabled { Text("Off") }
                }
            }
            Section {
                NavigationLink {
                    weatherDestination()
                } label: {
                    LabeledContent("Weather") {
                        weatherSummary
                    }
                }
            }
            Section {
                NavigationLink {
                    PermissionsContent(permissions: permissions)
                } label: {
                    Text("Permissions")
                }
            }
            Section {
                Toggle("Notify When Fully Charged", isOn: Binding(
                    get: { notifyWhenFullyCharged },
                    set: { setNotifyWhenFullyCharged($0) }
                ))
                Toggle("Notify About Firmware Updates", isOn: Binding(
                    get: { notifyAboutFirmwareUpdates },
                    set: { setNotifyAboutFirmwareUpdates($0) }
                ))
                FeedbackBanner(feedback: phoneAlertsFeedback)
            } header: {
                Text("Phone Notifications")
            } footer: {
                Text("Tells this phone when a watch finishes charging or a new PebbleOS is published. Turning these on asks for notification permission.")
            }
            Section {
                Toggle("Dictation from the Watch", isOn: Binding(
                    get: { voiceTranscription != .turnedOff && voiceTranscription != .unsupported },
                    set: { setVoiceTranscriptionEnabled($0) }
                ))
                .disabled(voiceTranscription == .unsupported)
                // Offered even while the phone's own language is unsupported:
                // choosing a supported one is exactly the way out of that.
                if !voiceLanguages.isEmpty {
                    Picker("Spoken Language", selection: Binding(
                        get: { spokenLanguage },
                        set: { chosen in
                            spokenLanguage = chosen
                            setVoiceSpokenLanguage(chosen)
                        }
                    )) {
                        Text("Same as the Phone").tag(String?.none)
                        ForEach(sortedVoiceLanguages, id: \.identifier) { language in
                            Text(verbatim: language.name).tag(String?.some(language.identifier))
                        }
                    }
                }
                if voiceTranscription != .turnedOff {
                    LabeledContent("Recognizer") {
                        voiceTranscriptionSummary
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("The watch records what you say and this app turns it into words here on the phone, without sending the sound anywhere. Turning this on downloads the recognizer for the chosen language.")
            }
            Section("Diagnostics") {
                Button("Prepare Diagnostic Report", systemImage: "stethoscope", action: prepareDiagnosticReport)
                // Beside the button that asked. This screen showed no feedback
                // at all before, so a report that could not be written left it
                // silent while the Apps tab spoke up about it.
                FeedbackBanner(feedback: diagnosticsFeedback)
                if let diagnosticReportURL {
                    ShareLink(item: diagnosticReportURL) {
                        Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                NavigationLink("Licenses") { LicensesView() }
            }
        }
        .navigationTitle(Text("Settings"))
        // Any of these can be changed in the system settings while the app is in the
        // background.
        .task { permissions = PhonePermissions.current() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions = PhonePermissions.current() }
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: PreviewSamples.weatherPlaces.map(\.name),
            areCompanionNotificationsEnabled: true,
            diagnosticReportURL: nil,
            diagnosticsFeedback: nil,
            voiceTranscription: .ready,
            voiceLanguages: ["en_US", "ja_JP", "de_DE"],
            setVoiceTranscriptionEnabled: { _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationSettingsDestination: { EmptyView() }
        )
    }
}

#Preview("The report could not be written") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: PreviewSamples.weatherPlaces.map(\.name),
            areCompanionNotificationsEnabled: true,
            // Nil alongside the failure: an earlier report is not offered for
            // sharing next to a message saying the report could not be made.
            diagnosticReportURL: nil,
            diagnosticsFeedback: .failure("The diagnostic report could not be created."),
            voiceTranscription: .ready,
            setVoiceTranscriptionEnabled: { _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationSettingsDestination: { EmptyView() }
        )
    }
}

#Preview("Recognizer downloading, notifications off") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: [],
            areCompanionNotificationsEnabled: false,
            diagnosticReportURL: URL(fileURLWithPath: "/tmp/pebble-diagnostics.txt"),
            diagnosticsFeedback: nil,
            voiceTranscription: .installing,
            voiceLanguages: ["en_US", "ja_JP", "de_DE"],
            setVoiceTranscriptionEnabled: { _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationSettingsDestination: { EmptyView() }
        )
    }
}

#Preview("Recognizer unsupported") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: [PreviewSamples.weatherPlaces[0].name],
            areCompanionNotificationsEnabled: true,
            diagnosticReportURL: nil,
            diagnosticsFeedback: nil,
            voiceTranscription: .unsupported,
            voiceLanguages: ["en_US", "ja_JP"],
            setVoiceTranscriptionEnabled: { _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationSettingsDestination: { EmptyView() }
        )
    }
}
