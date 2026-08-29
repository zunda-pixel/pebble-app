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

    var body: some View {
        Form {
            Section("Support") {
                LabeledContent("Supported Watches", value: "3 models")
                LabeledContent("Connection", value: "Bluetooth LE")
            }
            Section("Permissions") {
                LabeledContent("Bluetooth", value: "Required to connect to Pebble")
                LabeledContent("Calendar", value: "Used only when you sync timeline events")
                Button("Open Privacy Settings", systemImage: "gear") {
                    openPrivacySettings()
                }
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
            if !model.notificationSourceApps.isEmpty {
                Section {
                    ForEach(model.notificationSourceApps) { app in
                        Toggle(app.displayName, isOn: Binding(
                            get: { app.muteState == .never },
                            set: { enabled in
                                Task {
                                    await model.setNotificationSourceAppMute(
                                        bundleID: app.bundleID,
                                        muteState: enabled ? .never : .always
                                    )
                                }
                            }
                        ))
                    }
                    .onDelete { offsets in
                        Task { await model.removeNotificationSourceApps(at: offsets) }
                    }
                } header: {
                    Text("Phone App Notifications")
                } footer: {
                    Text("Apps the watch has seen sending notifications. Turning one off tells the watch to filter that app's notifications.")
                }
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
