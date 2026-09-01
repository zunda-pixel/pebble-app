import Defaults
public import SwiftUI
import API

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
    @State private var catalogSource = Defaults[.catalogSource]
        ?? PebbleAppCatalog.defaultSourceURL.absoluteString
    @State private var permissions = PhonePermissions()
    @Environment(\.scenePhase) private var scenePhase

    /// What the Weather row says before it is opened: how many places the watch
    /// is being told about.
    private var weatherSummary: Text {
        switch model.weatherPlaces.count {
        case 0: Text("Off")
        case 1: Text(verbatim: model.weatherPlaces[0].name)
        case let count: Text("\(count) places")
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WeatherView(model: model)
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
                    get: { model.companionNotificationsEnabled },
                    set: { model.setCompanionNotificationsEnabled($0) }
                ))
                Toggle("Quiet Hours", isOn: Binding(
                    get: { model.notificationPreferences.quietHoursEnabled },
                    set: { value in Task { await model.setQuietHours(enabled: value) } }
                ))
                if model.notificationPreferences.quietHoursEnabled {
                    Stepper(
                        "Starts at \(model.notificationPreferences.quietHoursStart):00",
                        value: Binding(
                            get: { model.notificationPreferences.quietHoursStart },
                            set: { value in Task { await model.setQuietHours(enabled: true, start: value) } }
                        ),
                        in: 0...23
                    )
                    Stepper(
                        "Ends at \(model.notificationPreferences.quietHoursEnd):00",
                        value: Binding(
                            get: { model.notificationPreferences.quietHoursEnd },
                            set: { value in Task { await model.setQuietHours(enabled: true, end: value) } }
                        ),
                        in: 0...23
                    )
                }
                if !(model.watchApplications + model.watchfaces).isEmpty {
                    DisclosureGroup("Per-App Notifications") {
                        ForEach(model.watchApplications + model.watchfaces) { application in
                            Toggle(application.displayName, isOn: Binding(
                                get: { !model.notificationPreferences.mutedApplicationIDs.contains(application.id) },
                                set: { enabled in
                                    Task { await model.setNotificationsEnabled(enabled, applicationID: application.id) }
                                }
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
                    NotificationAppsView(model: model)
                } label: {
                    LabeledContent("Phone App Notifications") {
                        Text("\(model.notificationSourceApps.count) apps")
                    }
                }
            } footer: {
                Text("Apps the watch has seen sending notifications, and what it does with each one.")
            }
            Section("Diagnostics") {
                Button("Prepare Diagnostic Report", systemImage: "stethoscope") {
                    Task { await model.prepareDiagnosticReport() }
                }
                if let diagnosticReportURL = model.diagnosticReportURL {
                    ShareLink(item: diagnosticReportURL) {
                        Label("Share Diagnostic Report", systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("App Catalog") {
                TextField("Catalog JSON URL", text: $catalogSource)
                Button("Update Catalog", systemImage: "arrow.clockwise") {
                    Task { await model.updateCatalog(source: catalogSource) }
                }
            }
        }
        .navigationTitle("Settings")
        // Any of these can be changed in the system settings while this app is
        // in the background, so they are read again on the way back rather than
        // remembered from the first look.
        .task { permissions = PhonePermissions.current() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions = PhonePermissions.current() }
        }
    }

    /// One permission, and what it is for when it has not been granted — the
    /// name alone does not say what the app would do with it.
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

    private func openPrivacySettings() {
#if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
#elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }
}
