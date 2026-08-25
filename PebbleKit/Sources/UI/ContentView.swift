public import SwiftUI
public import API
import Charts
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
            if let message = model.timelineActionStatusMessage {
                Text(message).foregroundStyle(.secondary)
            }
            Section("Calendar") {
                Button("Sync Calendar", systemImage: "calendar.badge.clock") {
                    Task { await model.synchronizeCalendar() }
                }
            }
        }
        .navigationTitle("Timeline")
        .task { await model.loadTimeline() }
    }
}

private struct HealthView: View {
    var model: AppModel
    @State private var period: HealthAnalysisPeriod = .week
    @State private var isImportingArchive = false

    var body: some View {
        List {
            Picker("Period", selection: $period) {
                ForEach(HealthAnalysisPeriod.allCases) { period in Text(period.rawValue.capitalized).tag(period) }
            }
            .pickerStyle(.segmented)
            Section("Today") {
                LabeledContent("Steps", value: "\(model.healthSamples.last?.steps ?? 0)")
                LabeledContent("Sleep", value: "\(model.healthSamples.last?.sleepMinutes ?? 0) min")
            }
            Section("Steps") {
                Chart(filteredSamples) { sample in
                    BarMark(x: .value("Date", sample.date), y: .value("Steps", sample.steps))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average", value: "\(averageSteps)")
                LabeledContent("Period Total", value: "\(totalSteps)")
                LabeledContent("Best Day", value: "\(bestStepCount)")
            }
            Section("Sleep") {
                Chart(filteredSamples) { sample in
                    LineMark(x: .value("Date", sample.date), y: .value("Minutes", sample.sleepMinutes))
                }
                .frame(minHeight: 180)
                LabeledContent("Daily Average", value: "\(averageSleep) min")
                LabeledContent("Tracked Days", value: "\(trackedSleepDays)")
            }
            Button("Sync Health Data", systemImage: "arrow.triangle.2.circlepath") {
                Task { await model.requestHealthSync() }
            }
            .disabled(model.connectedDevice == nil)
            #if os(iOS)
            Button("Sync with Apple Health", systemImage: "heart.fill") {
                Task { await model.synchronizeWithHealthKit() }
            }
            Button("Import from Apple Health", systemImage: "square.and.arrow.down") {
                Task { await model.importFromHealthKit() }
            }
            #endif
            Button("Export Health Data", systemImage: "square.and.arrow.up") {
                Task { await model.exportHealthData() }
            }
            if let url = model.healthExportURL { ShareLink(item: url) { Text("Share Export") } }
            Button("Import Health Archive", systemImage: "square.and.arrow.down.on.square") {
                isImportingArchive = true
            }
            Button("Delete Local Health Data", role: .destructive) {
                Task { await model.deleteHealthData() }
            }
            if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .task { await model.loadHealth() }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importHealthData(from: url) }
        }
    }

    private var filteredSamples: [PebbleHealthSample] {
        let start = Calendar.current.date(byAdding: .day, value: -period.days, to: Date()) ?? .distantPast
        return model.healthSamples.filter { $0.date >= start }
    }

    private var averageSteps: Int {
        filteredSamples.isEmpty ? 0 : filteredSamples.map(\.steps).reduce(0, +) / filteredSamples.count
    }

    private var totalSteps: Int { filteredSamples.map(\.steps).reduce(0, +) }

    private var bestStepCount: Int { filteredSamples.map(\.steps).max() ?? 0 }

    private var averageSleep: Int {
        filteredSamples.isEmpty ? 0 : filteredSamples.map(\.sleepMinutes).reduce(0, +) / filteredSamples.count
    }

    private var trackedSleepDays: Int { filteredSamples.count { $0.sleepMinutes > 0 } }
}

private enum CatalogKindFilter: String, CaseIterable, Identifiable {
    case all, watchapps, watchfaces
    var id: Self { self }
}

private enum CatalogSort: String, CaseIterable, Identifiable {
    case name, category, version
    var id: Self { self }
}

private struct CatalogView: View {
    var model: AppModel
    @State private var query = ""
    @State private var category = "All"
    @State private var kind: CatalogKindFilter = .all
    @State private var sort: CatalogSort = .name

    var body: some View {
        List {
            Section("Browse") {
                Picker("Type", selection: $kind) {
                    ForEach(CatalogKindFilter.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(CatalogSort.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section("Applications") {
                ForEach(filteredApplications) { application in
                    NavigationLink {
                        CatalogApplicationDetailView(application: application, model: model)
                    } label: {
                        CatalogApplicationRow(
                            application: application,
                            state: model.catalogInstallationState(for: application)
                        )
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Catalog")
        .toolbar {
            ToolbarItemGroup {
                Button("Update All", systemImage: "arrow.down.app") {
                    Task { await model.installCatalogUpdates() }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshCatalog() }
                }
                .disabled(model.isUpdatingCatalog)
            }
        }
        .overlay {
            if filteredApplications.isEmpty {
                ContentUnavailableView("No Catalog Apps", systemImage: "bag", description: Text("Catalog sources can be added in Settings."))
            }
        }
        .task {
            await model.loadCatalog()
            if model.catalogApplications.isEmpty { await model.refreshCatalog() }
        }
    }

    private var filteredApplications: [PebbleCatalogApplication] {
        let filtered = model.catalogApplications.filter { application in
            let matchesQuery = query.isEmpty
                || application.name.localizedCaseInsensitiveContains(query)
                || application.developer.localizedCaseInsensitiveContains(query)
                || application.summary.localizedCaseInsensitiveContains(query)
            let matchesCategory = category == "All" || application.category == category
            let matchesKind = kind == .all
                || (kind == .watchapps && application.kind == .watchapp)
                || (kind == .watchfaces && application.kind == .watchface)
            return matchesQuery && matchesCategory && matchesKind
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .name: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .category: lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            case .version: lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
            }
        }
    }

    private var categories: [String] {
        ["All"] + Set(model.catalogApplications.map(\.category)).sorted()
    }
}

private struct CatalogApplicationRow: View {
    var application: PebbleCatalogApplication
    var state: CatalogInstallationState

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: application.iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: application.kind == .watchface ? "clock" : "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name).font(.headline)
                Text("\(application.developer) · \(application.version)").foregroundStyle(.secondary)
                Text(application.category).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CatalogStateLabel(state: state)
        }
        .frame(minHeight: 52)
    }
}

private struct CatalogStateLabel: View {
    var state: CatalogInstallationState
    var body: some View {
        switch state {
        case .available: EmptyView()
        case .installed: Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .updateAvailable: Label("Update", systemImage: "arrow.down.circle").foregroundStyle(.tint)
        case .incompatible: Label("Incompatible", systemImage: "nosign").foregroundStyle(.secondary)
        }
    }
}

private struct CatalogApplicationDetailView: View {
    var application: PebbleCatalogApplication
    var model: AppModel

    var body: some View {
        List {
            Section {
                CatalogApplicationRow(
                    application: application,
                    state: model.catalogInstallationState(for: application)
                )
                if !application.summary.isEmpty { Text(application.summary) }
            }
            if !application.screenshotURLs.isEmpty {
                Section("Screenshots") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(application.screenshotURLs, id: \.self) { url in
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 220, height: 220)
                            }
                        }
                    }
                }
            }
            Section("Compatibility") {
                Text(application.supportedPlatforms.sorted().joined(separator: ", "))
            }
            if let releaseNotes = application.releaseNotes, !releaseNotes.isEmpty {
                Section("Release Notes") { Text(releaseNotes) }
            }
            Section {
                Button(installButtonTitle, systemImage: "arrow.down.app") {
                    Task { await model.installCatalogApplication(application) }
                }
                .disabled(!canInstall || model.installingCatalogApplicationID != nil)
                if model.installingCatalogApplicationID == application.id { ProgressView() }
                if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(application.name)
    }

    private var state: CatalogInstallationState { model.catalogInstallationState(for: application) }
    private var canInstall: Bool { state == .available || state == .updateAvailable }
    private var installButtonTitle: String { state == .updateAvailable ? "Update" : "Install" }
}

private struct ApplicationsView: View {
    var model: AppModel
    @State private var isChoosingPackage = false

    var body: some View {
        ApplicationsContent(
            watchApplications: model.watchApplications,
            watchfaces: model.watchfaces,
            activeWatchfaceID: model.activeWatchfaceID,
            favoriteWatchfaceIDs: model.favoriteWatchfaceIDs,
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
            },
            activateWatchface: { application in
                Task { await model.activateWatchface(application) }
            },
            toggleFavoriteWatchface: { application in
                model.toggleFavoriteWatchface(application)
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
    var activeWatchfaceID: UUID?
    var favoriteWatchfaceIDs: Set<UUID>
    var isLoading: Bool
    var errorMessage: String?
    var operationStatusMessage: String?
    var isOperationInProgress: Bool
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var removeApplication: (UUID) -> Void
    var reorderApplications: (PebbleApplicationKind, IndexSet, Int) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var activateWatchface: (PebbleApplication) -> Void
    var toggleFavoriteWatchface: (PebbleApplication) -> Void

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
                        activeWatchfaceID: activeWatchfaceID,
                        favoriteWatchfaceIDs: favoriteWatchfaceIDs,
                        isOperationInProgress: isOperationInProgress,
                        removeApplication: removeApplication,
                        configureApplication: configureApplication,
                        activateWatchface: activateWatchface,
                        toggleFavoriteWatchface: toggleFavoriteWatchface,
                        moveApplications: { offsets, destination in
                            reorderApplications(.watchapp, offsets, destination)
                        }
                    )
                }
                if !watchfaces.isEmpty {
                    ApplicationSection(
                        title: "Watchfaces",
                        applications: watchfaces,
                        activeWatchfaceID: activeWatchfaceID,
                        favoriteWatchfaceIDs: favoriteWatchfaceIDs,
                        isOperationInProgress: isOperationInProgress,
                        removeApplication: removeApplication,
                        configureApplication: configureApplication,
                        activateWatchface: activateWatchface,
                        toggleFavoriteWatchface: toggleFavoriteWatchface,
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
    var activeWatchfaceID: UUID?
    var favoriteWatchfaceIDs: Set<UUID>
    var isOperationInProgress: Bool
    var removeApplication: (UUID) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var activateWatchface: (PebbleApplication) -> Void
    var toggleFavoriteWatchface: (PebbleApplication) -> Void
    var moveApplications: (IndexSet, Int) -> Void

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationRow(
                    name: application.displayName,
                    companyName: application.companyName,
                    versionLabel: application.versionLabel,
                    kind: application.kind,
                    isActive: activeWatchfaceID == application.id,
                    isFavorite: favoriteWatchfaceIDs.contains(application.id),
                    isConfigurable: application.isConfigurable,
                    configure: { configureApplication(application) },
                    activate: { activateWatchface(application) },
                    toggleFavorite: { toggleFavoriteWatchface(application) }
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
    var isActive: Bool
    var isFavorite: Bool
    var isConfigurable: Bool
    var configure: () -> Void
    var activate: () -> Void
    var toggleFavorite: () -> Void

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
            if kind == .watchface {
                Button(isFavorite ? "Remove Favorite" : "Favorite", systemImage: isFavorite ? "star.fill" : "star", action: toggleFavorite)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button(isActive ? "Active" : "Activate", systemImage: isActive ? "checkmark.circle.fill" : "play.circle", action: activate)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isActive)
                    .accessibilityHint("Makes this the active watchface")
            }
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
    @State private var catalogSource = UserDefaults.standard.string(forKey: "appCatalogSource")
        ?? "https://appstore-api.repebble.com/api"
    @AppStorage("autoResumeFirmwareUpdate") private var autoResumeFirmwareUpdate = true

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
                Toggle("Resume Interrupted Updates", isOn: $autoResumeFirmwareUpdate)
                Button("Choose PBZ Firmware", systemImage: "externaldrive.badge.timemachine") {
                    isChoosingFirmware = true
                }
                .disabled(model.connectedDevice == nil)
                if model.firmwareRequiresConfirmation {
                    Button("Install Recovery Firmware", role: .destructive) {
                        Task { await model.confirmRecoveryFirmwareUpdate() }
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
                        Task { await model.discardPendingFirmwareUpdate() }
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
