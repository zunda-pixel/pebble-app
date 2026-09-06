import Defaults
public import SwiftUI
import PebbleProtocol

public struct PebbleSettingsView: View {
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
            notificationSourceAppCount: model.notifications.sourceApps.count,
            companionNotificationsEnabled: model.notifications.companionEnabled,
            notificationPreferences: model.notifications.preferences,
            applications: model.applications.apps + model.applications.watchfaces,
            diagnosticReportURL: model.diagnostics.reportURL,
            voiceTranscription: model.voiceTranscriptionReadiness,
            setVoiceTranscriptionEnabled: { enabled in
                Task { await model.setVoiceTranscriptionEnabled(enabled) }
            },
            setCompanionNotificationsEnabled: { model.setCompanionNotificationsEnabled($0) },
            setQuietHours: { enabled, start, end in
                Task { await model.setQuietHours(enabled: enabled, start: start, end: end) }
            },
            setNotificationsEnabled: { enabled, applicationID in
                Task { await model.setNotificationsEnabled(enabled, applicationID: applicationID) }
            },
            prepareDiagnosticReport: { Task { await model.prepareDiagnosticReport() } },
            weatherDestination: { WeatherView(model: model) },
            notificationAppsDestination: { NotificationAppsView(model: model) }
        )
        // iOS can take the recognizer's model back, so what is on the phone is
        // read again each time the screen appears rather than remembered.
        .task { await model.refreshVoiceTranscriptionReadiness() }
    }
}

struct SettingsContent<WeatherDestination: View, NotificationAppsDestination: View>: View {
    var weatherPlaceNames: [String]
    var notificationSourceAppCount: Int
    var companionNotificationsEnabled: Bool
    var notificationPreferences: NotificationDeliveryPreferences
    var applications: [WatchApplication]
    var diagnosticReportURL: URL?
    var voiceTranscription: VoiceTranscriptionReadiness
    var setVoiceTranscriptionEnabled: (Bool) -> Void
    var setCompanionNotificationsEnabled: (Bool) -> Void
    var setQuietHours: (_ enabled: Bool, _ start: Int?, _ end: Int?) -> Void
    var setNotificationsEnabled: (Bool, UUID) -> Void
    var prepareDiagnosticReport: () -> Void
    @ViewBuilder var weatherDestination: () -> WeatherDestination
    @ViewBuilder var notificationAppsDestination: () -> NotificationAppsDestination

    @State private var permissions = PhonePermissions()
    @Environment(\.scenePhase) private var scenePhase

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
                permissionRow("Bluetooth", permissions.bluetooth)
                permissionRow("Calendar", permissions.calendar)
                permissionRow("Reminders", permissions.reminders)
                permissionRow("Location", permissions.location)
                permissionRow("Health", permissions.health)
                Button("Open Privacy Settings", systemImage: "gear") {
                    openPrivacySettings()
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("What this app has been allowed to read. Health shows whether it may write to your Health data: iOS gives no way to ask whether reading was allowed.")
            }
            Section {
                Toggle("Watch App Notifications", isOn: Binding(
                    get: { companionNotificationsEnabled },
                    set: { setCompanionNotificationsEnabled($0) }
                ))
                Toggle("Quiet Hours", isOn: Binding(
                    get: { notificationPreferences.quietHoursEnabled },
                    set: { value in setQuietHours(value, nil, nil) }
                ))
                if notificationPreferences.quietHoursEnabled {
                    Stepper(
                        "Starts at \(notificationPreferences.quietHoursStart):00",
                        value: Binding(
                            get: { notificationPreferences.quietHoursStart },
                            set: { value in setQuietHours(true, value, nil) }
                        ),
                        in: 0...23
                    )
                    Stepper(
                        "Ends at \(notificationPreferences.quietHoursEnd):00",
                        value: Binding(
                            get: { notificationPreferences.quietHoursEnd },
                            set: { value in setQuietHours(true, nil, value) }
                        ),
                        in: 0...23
                    )
                }
                if !applications.isEmpty {
                    DisclosureGroup("Per-App Notifications") {
                        ForEach(applications) { application in
                            Toggle(application.displayName, isOn: Binding(
                                get: { !notificationPreferences.mutedApplicationIDs.contains(application.id) },
                                set: { enabled in setNotificationsEnabled(enabled, application.id) }
                            ))
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("System notifications are delivered directly to a paired Pebble using Apple Notification Center Service. This switch controls notifications created by installed watch apps. Test notifications can be sent from each watch's detail page.")
            }
            Section {
                NavigationLink {
                    notificationAppsDestination()
                } label: {
                    LabeledContent("Phone App Notifications") {
                        Text("\(notificationSourceAppCount) apps")
                    }
                }
            } footer: {
                Text("Apps the watch has seen sending notifications, and what it does with each one.")
            }
            Section {
                Toggle("Dictation from the Watch", isOn: Binding(
                    get: { voiceTranscription != .turnedOff && voiceTranscription != .unsupported },
                    set: { setVoiceTranscriptionEnabled($0) }
                ))
                .disabled(voiceTranscription == .unsupported)
                if voiceTranscription != .turnedOff {
                    LabeledContent("Recognizer") {
                        voiceTranscriptionSummary
                    }
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("The watch records what you say and this app turns it into words here on the phone, without sending the sound anywhere. Turning this on downloads the recognizer for the language the phone is set to.")
            }
            Section("Diagnostics") {
                Button("Prepare Diagnostic Report", systemImage: "stethoscope", action: prepareDiagnosticReport)
                if let diagnosticReportURL {
                    ShareLink(item: diagnosticReportURL) {
                        Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                    }
                }
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

    private func permissionRow(
        _ name: LocalizedStringKey,
        _ state: PhonePermissionState
    ) -> some View {
        LabeledContent {
            Text(state.title)
                .foregroundStyle(state.isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        } label: {
            Text(name)
        }
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: PreviewSamples.weatherPlaces.map(\.name),
            notificationSourceAppCount: PreviewSamples.notificationApps.count,
            companionNotificationsEnabled: true,
            notificationPreferences: NotificationDeliveryPreferences(),
            applications: PreviewSamples.watchApplications + PreviewSamples.watchfaces,
            diagnosticReportURL: nil,
            voiceTranscription: .ready,
            setVoiceTranscriptionEnabled: { _ in },
            setCompanionNotificationsEnabled: { _ in },
            setQuietHours: { _, _, _ in },
            setNotificationsEnabled: { _, _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationAppsDestination: { EmptyView() }
        )
    }
}

#Preview("Quiet hours on, nothing installed") {
    NavigationStack {
        SettingsContent(
            weatherPlaceNames: [],
            notificationSourceAppCount: 0,
            companionNotificationsEnabled: false,
            notificationPreferences: NotificationDeliveryPreferences(
                quietHoursEnabled: true,
                quietHoursStart: 22,
                quietHoursEnd: 7
            ),
            applications: [],
            diagnosticReportURL: URL(fileURLWithPath: "/tmp/pebble-diagnostics.txt"),
            voiceTranscription: .needsInstalling,
            setVoiceTranscriptionEnabled: { _ in },
            setCompanionNotificationsEnabled: { _ in },
            setQuietHours: { _, _, _ in },
            setNotificationsEnabled: { _, _ in },
            prepareDiagnosticReport: {},
            weatherDestination: { EmptyView() },
            notificationAppsDestination: { EmptyView() }
        )
    }
}
