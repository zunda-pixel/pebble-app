public import SwiftUI
public import API
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
@MainActor
public func makeQEMUPebbleClient() -> any PebbleClient {
    QEMUPebbleClient()
}
#endif

public struct ContentView: View {
    @State private var model: AppModel

    public init() {
        self.init(client: CoreBluetoothPebbleClient())
    }

    public init(client: any PebbleClient) {
        _model = State(initialValue: AppModel(client: client))
    }

    public var body: some View {
        AppRootView(model: model)
            .task { await model.start() }
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case apps
    case timeline
    case health
    case catalog
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .devices:
            "Devices"
        case .apps:
            "Apps"
        case .timeline:
            "Timeline"
        case .health:
            "Health"
        case .catalog:
            "Catalog"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .devices:
            "applewatch"
        case .apps:
            "square.grid.2x2"
        case .timeline:
            "calendar"
        case .health:
            "heart"
        case .catalog:
            "bag"
        case .settings:
            "gearshape"
        }
    }
}

private struct AppRootView: View {
    var model: AppModel

    var body: some View {
#if os(macOS)
        MacRootView(model: model)
#else
        IOSRootView(model: model)
#endif
    }
}

#if os(macOS)
private struct MacRootView: View {
    var model: AppModel
    @State private var selection: AppSection? = .devices

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Pebble")
        } detail: {
            NavigationStack {
                SectionContent(section: selection ?? .devices, model: model)
            }
        }
    }
}
#else
private struct IOSRootView: View {
    var model: AppModel

    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.systemImage) {
                    NavigationStack {
                        SectionContent(section: section, model: model)
                    }
                }
            }
        }
    }
}
#endif

private struct SectionContent: View {
    var section: AppSection
    var model: AppModel

    var body: some View {
        switch section {
        case .devices:
            DevicesView(model: model)
        case .apps:
            ApplicationsView(model: model)
        case .timeline:
            TimelineView(model: model)
        case .health:
            HealthView(model: model)
        case .catalog:
            CatalogView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}

private struct TimelineView: View {
    var model: AppModel
    @State private var title = ""
    @State private var date = Date()

    var body: some View {
        List {
            Section("New Pin") {
                TextField("Title", text: $title)
                DatePicker("Date", selection: $date)
                Button("Add to Timeline", systemImage: "plus") {
                    let value = title
                    title = ""
                    Task { await model.addTimelinePin(title: value, date: date) }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Pins") {
                ForEach(model.timelinePins) { pin in
                    LabeledContent(pin.title) { Text(pin.timestamp, format: .dateTime) }
                }
                .onDelete { offsets in Task { await model.removeTimelinePins(at: offsets) } }
            }
        }
        .navigationTitle("Timeline")
        .task { await model.loadTimeline() }
    }
}

private struct HealthView: View {
    var model: AppModel

    var body: some View {
        List {
            Section("Today") {
                LabeledContent("Steps", value: "\(model.healthSamples.last?.steps ?? 0)")
                LabeledContent("Sleep", value: "\(model.healthSamples.last?.sleepMinutes ?? 0) min")
            }
            Button("Sync Health Data", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.requestHealthSync() }
            }
            .disabled(model.connectedDevice == nil)
            #if os(iOS)
            Button("Sync with Apple Health", systemImage: "heart.fill") {
                Task { await model.synchronizeWithHealthKit() }
            }
            #endif
            if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .task { await model.loadHealth() }
    }
}

private struct CatalogView: View {
    var model: AppModel
    @State private var query = ""

    var body: some View {
        List(filteredApplications) { application in
            LabeledContent {
                Button("Install") { Task { await model.installCatalogApplication(application) } }
            } label: {
                VStack(alignment: .leading) {
                    Text(application.name).font(.headline)
                    Text("\(application.developer) · \(application.version)").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Catalog")
        .overlay {
            if filteredApplications.isEmpty {
                ContentUnavailableView("No Catalog Apps", systemImage: "bag", description: Text("Catalog sources can be added in Settings."))
            }
        }
        .task { await model.loadCatalog() }
    }

    private var filteredApplications: [PebbleCatalogApplication] {
        query.isEmpty ? model.catalogApplications : model.catalogApplications.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.developer.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct ApplicationsView: View {
    var model: AppModel
    @State private var isChoosingPackage = false

    var body: some View {
        ApplicationsContent(
            watchApplications: model.watchApplications,
            watchfaces: model.watchfaces,
            isLoading: model.isLoadingApplications,
            errorMessage: model.applicationLibraryErrorMessage,
            operationStatusMessage: model.applicationManagementStatusMessage,
            isOperationInProgress: model.isApplicationManagementBusy,
            installingApplicationName: model.installingApplicationName,
            installationProgress: model.installationProgress,
            removeApplication: { applicationID in
                Task { await model.removeApplication(id: applicationID) }
            },
            reorderApplications: { kind, offsets, destination in
                Task {
                    await model.reorderApplications(
                        kind: kind,
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            },
            configureApplication: { application in
                Task { await model.configureApplication(application) }
            }
        )
        .navigationTitle("Apps")
        .task { await model.loadApplications() }
        .toolbar {
            ToolbarItem {
                if model.isImportingApplication {
                    ProgressView()
                        .accessibilityLabel("Importing Pebble application")
                } else {
                    Button("Import", systemImage: "square.and.arrow.down") {
                        isChoosingPackage = true
                    }
                    .accessibilityHint("Choose a PBW package from Files")
                    .disabled(model.isApplicationManagementBusy)
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosingPackage,
            allowedContentTypes: [.pebblePackage]
        ) { result in
            guard case .success(let url) = result else {
                return
            }
            Task { await model.importApplication(from: url) }
        }
        .sheet(isPresented: Binding(
            get: { model.configurationURL != nil },
            set: { presented in
                if !presented { Task { await model.closeConfiguration() } }
            }
        )) {
            NavigationStack {
                Group {
                    if let configurationURL = model.configurationURL {
                        ConfigurationWebView(url: configurationURL) { response in
                            Task { await model.closeConfiguration(response: response) }
                        }
                    }
                }
                .navigationTitle(model.configurationApplication?.displayName ?? "App Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { Task { await model.closeConfiguration() } }
                    }
                }
            }
        }
    }
}

private extension UTType {
    static var pebblePackage: UTType {
        UTType(filenameExtension: "pbw") ?? .data
    }
}

private struct ApplicationsContent: View {
    var watchApplications: [PebbleApplication]
    var watchfaces: [PebbleApplication]
    var isLoading: Bool
    var errorMessage: String?
    var operationStatusMessage: String?
    var isOperationInProgress: Bool
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var removeApplication: (UUID) -> Void
    var reorderApplications: (PebbleApplicationKind, IndexSet, Int) -> Void
    var configureApplication: (PebbleApplication) -> Void

    var body: some View {
        if isLoading && watchApplications.isEmpty && watchfaces.isEmpty {
            List(0..<3, id: \.self) { _ in
                ApplicationPlaceholderRow()
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel("Loading applications")
        } else if watchApplications.isEmpty && watchfaces.isEmpty {
            ContentUnavailableView(
                "No Apps",
                systemImage: "square.grid.2x2",
                description: Text("Imported watch apps and watchfaces will appear here.")
            )
        } else {
            List {
                if let operationStatusMessage {
                    Section {
                        Label(operationStatusMessage, systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                }
                if let installingApplicationName,
                   let installationProgress {
                    InstallationProgressSection(
                        applicationName: installingApplicationName,
                        progress: installationProgress
                    )
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if !watchApplications.isEmpty {
                    ApplicationSection(
                        title: "Watch Apps",
                        applications: watchApplications,
                        isOperationInProgress: isOperationInProgress,
                        removeApplication: removeApplication,
                        configureApplication: configureApplication,
                        moveApplications: { offsets, destination in
                            reorderApplications(.watchapp, offsets, destination)
                        }
                    )
                }
                if !watchfaces.isEmpty {
                    ApplicationSection(
                        title: "Watchfaces",
                        applications: watchfaces,
                        isOperationInProgress: isOperationInProgress,
                        removeApplication: removeApplication,
                        configureApplication: configureApplication,
                        moveApplications: { offsets, destination in
                            reorderApplications(.watchface, offsets, destination)
                        }
                    )
                }
            }
        }
    }
}

private struct InstallationProgressSection: View {
    var applicationName: String
    var progress: PutBytesTransferProgress

    var body: some View {
        Section("Installing") {
            VStack(alignment: .leading, spacing: 8) {
                Label(applicationName, systemImage: "arrow.down.app")
                    .font(.headline)
                if progress.totalBytes > 0 {
                    ProgressView(
                        value: Double(progress.bytesSent),
                        total: Double(progress.totalBytes)
                    )
                    Text("\(progress.bytesSent, format: .number) of \(progress.totalBytes, format: .number) bytes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .accessibilityLabel("Preparing installation")
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ApplicationSection: View {
    var title: LocalizedStringKey
    var applications: [PebbleApplication]
    var isOperationInProgress: Bool
    var removeApplication: (UUID) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var moveApplications: (IndexSet, Int) -> Void

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationRow(
                    name: application.displayName,
                    companyName: application.companyName,
                    versionLabel: application.versionLabel,
                    kind: application.kind,
                    isConfigurable: application.isConfigurable,
                    configure: { configureApplication(application) }
                )
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        removeApplication(application.id)
                    }
                    .disabled(isOperationInProgress)
                }
            }
            .onMove(perform: moveApplications)
            .moveDisabled(isOperationInProgress)
        }
    }
}

private struct ApplicationRow: View {
    var name: String
    var companyName: String
    var versionLabel: String
    var kind: PebbleApplicationKind
    var isConfigurable: Bool
    var configure: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: kind == .watchface ? "clock" : "square.grid.2x2")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                if !companyName.isEmpty {
                    Text(companyName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isConfigurable {
                Button("Configure", systemImage: "gearshape", action: configure)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens this watch application's settings")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}

private struct ApplicationPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
            VStack(alignment: .leading, spacing: 4) {
                Text("Application Name")
                    .font(.headline)
                Text("Developer")
                    .font(.subheadline)
            }
        }
        .frame(minHeight: 44)
    }
}

private struct DevicesView: View {
    var model: AppModel

    var body: some View {
        List {
            if let device = model.connectedDevice {
                Section("Connected") {
                    ConnectedDeviceRow(device: device)

                    Button("Disconnect", role: .destructive) {
                        Task {
                            await model.disconnect()
                        }
                    }
                }
            }

            Section("Nearby") {
                if case .failed(let error) = model.connectionState {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Bluetooth error: \(error.message)")
                }

                if model.discoveredDevices.isEmpty {
                    ContentUnavailableView(
                        "No Watches Found",
                        systemImage: "applewatch.radiowaves.left.and.right",
                        description: Text("Scan for a Pebble 2 Duo, Pebble Time 2, or Pebble Round 2.")
                    )
                } else {
                    ForEach(model.discoveredDevices) { device in
                        DiscoveredDeviceRow(device: device) {
                            Task {
                                await model.connect(to: device)
                            }
                        }
                    }
                }
            }

            if !model.savedWatches.isEmpty {
                Section("My Watches") {
                    ForEach(model.savedWatches) { watch in
                        SavedWatchRow(
                            watch: watch,
                            setAutomaticallyConnects: { enabled in
                                Task {
                                    await model.setAutomaticallyConnects(enabled, watchID: watch.id)
                                }
                            },
                            forget: {
                                Task { await model.forgetWatch(id: watch.id) }
                            }
                        )
                    }
                }
            }

            if let errorMessage = model.watchManagementErrorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("Devices")
        .task { await model.loadSavedWatches() }
        .toolbar {
            ToolbarItem {
                Button("Scan", systemImage: "arrow.clockwise") {
                    Task {
                        await model.scan()
                    }
                }
                .disabled(isBusy)
            }
        }
        .overlay {
            if isBusy {
                ProgressView(progressTitle)
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
            }
        }
    }

    private var isBusy: Bool {
        switch model.connectionState {
        case .scanning, .connecting, .negotiating, .reconnecting:
            true
        default:
            false
        }
    }

    private var progressTitle: String {
        switch model.connectionState {
        case .scanning:
            "Scanning…"
        case .connecting:
            "Connecting…"
        case .negotiating:
            "Setting Up…"
        case .reconnecting:
            "Reconnecting…"
        default:
            "Working…"
        }
    }
}

private struct SavedWatchRow: View {
    var watch: SavedPebbleWatch
    var setAutomaticallyConnects: (Bool) -> Void
    var forget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(watch.lastConnectedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading) {
                    Text(watch.name)
                    Text(watch.model.displayName)
                        .foregroundStyle(.secondary)
                    if let firmwareVersion = watch.firmwareVersion {
                        Text(firmwareVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Connect Automatically", isOn: Binding(
                get: { watch.automaticallyConnects },
                set: setAutomaticallyConnects
            ))
            Button("Forget Watch", role: .destructive, action: forget)
        }
        .padding(.vertical, 4)
    }
}

private struct ConnectedDeviceRow: View {
    var device: PebbleDevice

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                if let firmwareVersion = device.firmwareVersion {
                    Text(firmwareVersion)
                }
                if let batteryLevel = device.batteryLevel {
                    Label("\(batteryLevel)%", systemImage: "battery.75percent")
                        .foregroundStyle(.secondary)
                }
                if let serialNumber = device.serialNumber {
                    Text(serialNumber)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(device.name)
                    Text(device.model.displayName)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "applewatch")
            }
        }
    }
}

private struct DiscoveredDeviceRow: View {
    var device: DiscoveredPebble
    var connect: () -> Void

    var body: some View {
        Button(action: connect) {
            LabeledContent {
                Text("\(device.signalStrength) dBm")
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.model.displayName)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Connects to this watch")
    }
}

private struct PlaceholderView: View {
    var title: String
    var description: String
    var systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        .navigationTitle(title)
    }
}

private struct SettingsView: View {
    var model: AppModel
    @State private var isChoosingFirmware = false
    @State private var catalogSource = UserDefaults.standard.string(forKey: "appCatalogSource") ?? ""

    var body: some View {
        Form {
            Section("Support") {
                LabeledContent("Supported Watches", value: "3 models")
                LabeledContent("Connection", value: "Bluetooth LE")
            }
            Section {
                Toggle("Watch App Notifications", isOn: Binding(
                    get: { model.companionNotificationsEnabled },
                    set: { model.setCompanionNotificationsEnabled($0) }
                ))
                Button("Send Test Notification", systemImage: "bell.badge") {
                    Task { await model.sendTestNotification() }
                }
                .disabled(model.connectedDevice == nil)
                if let notificationStatusMessage = model.notificationStatusMessage {
                    Label(notificationStatusMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("System notifications are delivered directly to a paired Pebble using Apple Notification Center Service. This switch controls notifications created by installed watch apps.")
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
                Button("Choose PBZ Firmware", systemImage: "externaldrive.badge.timemachine") {
                    isChoosingFirmware = true
                }
                .disabled(model.connectedDevice == nil)
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
    }
}

private extension UTType {
    static var pebbleFirmware: UTType { UTType(filenameExtension: "pbz") ?? .data }
}

private struct ConfigurationNavigationDecider: WebPage.NavigationDeciding {
    var closeHandler: @MainActor @Sendable (String?) -> Void

    mutating func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme?.lowercased() == "pebblejs", url.host?.lowercased() == "close" {
            let encodedResponse = url.fragment ?? url.query
            closeHandler(encodedResponse?.removingPercentEncoding ?? encodedResponse)
            return .cancel
        }
        return ["https", "http"].contains(url.scheme?.lowercased()) ? .allow : .cancel
    }
}

private struct ConfigurationWebView: View {
    var url: URL
    var closeHandler: @MainActor @Sendable (String?) -> Void
    @State private var page: WebPage
    @State private var loadErrorMessage: String?

    init(url: URL, closeHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        self.url = url
        self.closeHandler = closeHandler
        _page = State(initialValue: WebPage(
            navigationDecider: ConfigurationNavigationDecider(closeHandler: closeHandler)
        ))
    }

    var body: some View {
        Group {
            if let loadErrorMessage {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(loadErrorMessage)
                )
            } else {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
            }
        }
        .task(id: url) {
            loadErrorMessage = nil
            do {
                for try await _ in page.load(url) {}
            } catch {
                if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                    loadErrorMessage = "The watch app's settings service could not be found."
                } else {
                    loadErrorMessage = "The watch app's settings page could not be loaded."
                }
            }
        }
    }
}

#Preview {
    ContentView(client: MockPebbleClient())
}
