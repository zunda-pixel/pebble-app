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
    @State private var isChoosingFirmware = false
    @State private var catalogSource = UserDefaults.standard.string(forKey: "appCatalogSource")
        ?? "https://appstore-api.repebble.com/api"
    @AppStorage("autoResumeFirmwareUpdate") private var autoResumeFirmwareUpdate = true
    @State private var destructiveFirmwareAction: FirmwareDestructiveAction?

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
            Section("Firmware") {
                Toggle("Resume Interrupted Updates", isOn: $autoResumeFirmwareUpdate)
                Button("Choose PBZ Firmware", systemImage: "externaldrive.badge.timemachine") {
                    isChoosingFirmware = true
                }
                // A watch that only stays connected for a few seconds cannot be
                // handed a file in time, so a saved watch is target enough.
                .disabled(model.connectedDevice == nil && model.savedWatches.count != 1)
                if model.firmwareRequiresConfirmation {
                    Button("Install Recovery Firmware", role: .destructive) {
                        destructiveFirmwareAction = .installRecovery
                    }
                }
                if let journal = model.firmwareUpdateJournal {
                    LabeledContent("Update State", value: journal.phase.rawValue)
                    if let previousVersion = journal.previousVersion {
                        LabeledContent("Current Version", value: previousVersion)
                    }
                    if let targetVersion = journal.targetVersion {
                        LabeledContent("Target Version", value: targetVersion)
                    }
                    if let progress = model.firmwareUpdateProgress, progress.totalBytes > 0 {
                        ProgressView(value: Double(progress.bytesSent), total: Double(progress.totalBytes))
                        Text("\(progress.bytesSent, format: .number) of \(progress.totalBytes, format: .number) bytes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel Update", role: .destructive) {
                        Task { await model.cancelFirmwareUpdate() }
                    }
                    Button("Discard Recovery Data", role: .destructive) {
                        destructiveFirmwareAction = .discardRecovery
                    }
                }
                if let message = model.firmwareUpdateStatusMessage { Text(message).foregroundStyle(.secondary) }
            }
            Section("App Catalog") {
                TextField("Catalog JSON URL", text: $catalogSource)
                Button("Update Catalog", systemImage: "arrow.clockwise") {
                    Task { await model.updateCatalog(source: catalogSource) }
                }
            }
        }
        .navigationTitle("Settings")
        .fileImporter(isPresented: $isChoosingFirmware, allowedContentTypes: [.pebbleFirmware]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.installFirmware(from: url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let firmwareURL = urls.first(where: { $0.pathExtension.lowercased() == "pbz" }) else {
                return false
            }
            Task { await model.installFirmware(from: firmwareURL) }
            return true
        }
        .confirmationDialog(
            destructiveFirmwareAction?.title ?? "Confirm firmware action",
            isPresented: Binding(
                get: { destructiveFirmwareAction != nil },
                set: { if !$0 { destructiveFirmwareAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(destructiveFirmwareAction?.buttonTitle ?? "Continue", role: .destructive) {
                let action = destructiveFirmwareAction
                destructiveFirmwareAction = nil
                Task {
                    switch action {
                    case .installRecovery: await model.confirmRecoveryFirmwareUpdate()
                    case .discardRecovery: await model.discardPendingFirmwareUpdate()
                    case nil: break
                    }
                }
            }
            Button("Cancel", role: .cancel) { destructiveFirmwareAction = nil }
        } message: {
            Text(destructiveFirmwareAction?.message ?? "Review this action before continuing.")
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

enum FirmwareDestructiveAction: Identifiable {
    case installRecovery
    case discardRecovery

    var id: Self { self }

    var title: String {
        switch self {
        case .installRecovery: "Install recovery firmware?"
        case .discardRecovery: "Discard recovery data?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .installRecovery: "Install Recovery Firmware"
        case .discardRecovery: "Discard Recovery Data"
        }
    }

    var message: String {
        switch self {
        case .installRecovery: "Installing recovery firmware can make the watch temporarily unavailable. Keep it connected until the update completes."
        case .discardRecovery: "The interrupted update can no longer be resumed after its recovery data is discarded."
        }
    }
}
