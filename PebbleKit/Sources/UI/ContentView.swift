public import SwiftUI
public import API
import Charts
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public extension Notification.Name {
    static var pebbleScanRequested: Notification.Name { Notification.Name("PebbleScanRequested") }
    static var pebbleSectionRequested: Notification.Name { Notification.Name("PebbleSectionRequested") }
}

@MainActor
public func makeDefaultPebbleClient() -> any PebbleClient {
    CoreBluetoothPebbleClient()
}

/// Creates one Bluetooth client per watch so several watches can stay
/// connected at the same time. The restoration identifier must be stable and
/// unique per watch for CoreBluetooth state restoration.
@MainActor
public func makeDefaultPebbleClientFactory() -> @MainActor (String) -> any PebbleClient {
    { deviceID in
        CoreBluetoothPebbleClient(restoreIdentifier: "dev.pebble.central.watch.\(deviceID)")
    }
}

#if os(macOS)
@MainActor
public func makeQEMUPebbleClient() -> any PebbleClient {
    QEMUPebbleClient()
}
#endif

public struct ContentView: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        _model = State(initialValue: AppModel(
            client: CoreBluetoothPebbleClient(),
            clientFactory: makeDefaultPebbleClientFactory()
        ))
    }

    public init(client: any PebbleClient) {
        _model = State(initialValue: AppModel(client: client))
    }

    public init(model: AppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        AppRootView(model: model)
            .task { await model.start() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await model.applicationDidBecomeActive() }
            }
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case apps
    case timeline
    case health
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
        case .settings:
            "gearshape"
        }
    }
}

private struct AppRootView: View {
    var model: AppModel
    @AppStorage("hasCompletedPebbleOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
#if os(macOS)
            MacRootView(model: model)
#else
            IOSRootView(model: model)
#endif
        }
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
        }
    }
}

#if os(macOS)
private struct MacRootView: View {
    var model: AppModel
    @State private var selection: AppSection? = .devices

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases.filter { $0 != .settings }, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Pebble")
        } detail: {
            NavigationStack {
                VStack(spacing: 0) {
                    ConnectionStatusBanner(state: model.connectionState) {
                        Task { await model.disconnect() }
                    }
                    SectionContent(section: selection ?? .devices, model: model)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onReceive(NotificationCenter.default.publisher(for: .pebbleScanRequested)) { _ in
            selection = .devices
        }
        .onReceive(NotificationCenter.default.publisher(for: .pebbleSectionRequested)) { notification in
            guard let rawValue = notification.object as? String,
                  let requestedSection = AppSection(rawValue: rawValue) else { return }
            selection = requestedSection
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
                        .toolbar {
                            ToolbarItem(placement: .status) {
                                ConnectionStatusBanner(state: model.connectionState) {
                                    Task { await model.disconnect() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif

private struct OnboardingView: View {
    var complete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Welcome to Pebble", systemImage: "applewatch")
                .font(.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Connect your Pebble, install watch apps, and keep timeline and health data synchronized.")
                .font(.body)
            VStack(alignment: .leading, spacing: 12) {
                Label("Turn on your Pebble and keep it nearby.", systemImage: "1.circle")
                Label("Allow Bluetooth access when requested.", systemImage: "2.circle")
                Label("Choose Devices, then Scan to connect.", systemImage: "3.circle")
            }
            .accessibilityElement(children: .contain)
            HStack {
                Spacer()
                Button("Get Started", action: complete)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520)
    }
}

private struct ConnectionStatusBanner: View {
    var state: PebbleConnectionState
    var cancelReconnect: (() -> Void)? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .reconnecting = state, let cancelReconnect {
                Button("Cancel", action: cancelReconnect)
                    .font(.callout)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
        .accessibilityLabel("Connection status: \(title)")
    }

    private var title: String {
        switch state {
        case .idle: "Not connected"
        case .scanning: "Scanning for watches…"
        case .connecting: "Connecting…"
        case .negotiating: "Setting up connection…"
        case .connected(let device): "Connected to \(device.name)"
        case .reconnecting: "Connection lost — reconnecting…"
        case .failed(let error): "Connection failed: \(error.message)"
        }
    }

    private var systemImage: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .scanning, .connecting, .negotiating, .reconnecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "applewatch.slash"
        }
    }
}

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
    @State private var isConfirmingHealthDeletion = false

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
                isConfirmingHealthDeletion = true
            }
            if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
        }
        .navigationTitle("Health")
        .task { await model.loadHealth() }
        .fileImporter(isPresented: $isImportingArchive, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task { await model.importHealthData(from: url) }
        }
        .confirmationDialog(
            "Delete all local health data?",
            isPresented: $isConfirmingHealthDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Health Data", role: .destructive) {
                Task { await model.deleteHealthData() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes locally stored step and sleep history. This action cannot be undone.")
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

/// The app catalog, presented as a sheet from the Apps tab's plus button.
private struct CatalogView: View {
    var model: AppModel
    var isImportingApplication: Bool = false
    var isImportDisabled: Bool = false
    var importApplication: (() -> Void)?
    @State private var query = ""
    @State private var category = "All"
    @State private var kind: CatalogKindFilter = .all
    @State private var sort: CatalogSort = .name
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            catalogList
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private var catalogList: some View {
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
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup {
                if let importApplication {
                    if isImportingApplication {
                        ProgressView()
                            .accessibilityLabel("Importing Pebble application")
                    } else {
                        Button("Import", systemImage: "square.and.arrow.down", action: importApplication)
                            .accessibilityHint("Choose a PBW package from Files")
                            .disabled(isImportDisabled)
                    }
                }
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
            .accessibilityHidden(true)
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
                                .accessibilityLabel("Screenshot of \(application.name)")
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
    @Environment(\.undoManager) private var undoManager
    @State private var isChoosingPackage = false
    @State private var isShowingCatalog = false
    @State private var pendingRemovalID: UUID?
    @State private var selectedWatchID: String?

    // The watch whose install state is shown: the picked one while it stays
    // connected, otherwise the primary connection.
    private var displayedWatchID: String? {
        if let selectedWatchID,
           model.connectedDevices.contains(where: { $0.id == selectedWatchID }) {
            return selectedWatchID
        }
        return model.connectedDevice?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.connectedDevices.count > 1 {
                Picker("Watch", selection: Binding(
                    get: { displayedWatchID ?? "" },
                    set: { selectedWatchID = $0 }
                )) {
                    ForEach(model.connectedDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            applicationsContent
        }
    }

    private var applicationsContent: some View {
        ApplicationsContent(
            watchApplications: model.watchApplications,
            watchfaces: model.watchfaces,
            activeWatchfaceID: model.activeWatchfaceID,
            favoriteWatchfaceIDs: model.favoriteWatchfaceIDs,
            installedApplicationIDs: displayedWatchID.map { model.installedApplicationIDs(on: $0) },
            isLoading: model.isLoadingApplications,
            errorMessage: model.applicationLibraryErrorMessage,
            operationStatusMessage: model.applicationManagementStatusMessage,
            isOperationInProgress: model.isApplicationManagementBusy,
            installingApplicationName: model.installingApplicationName,
            installationProgress: model.installationProgress,
            removeApplication: { applicationID in
                pendingRemovalID = applicationID
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
                undoManager?.registerUndo(withTarget: model) { target in
                    target.toggleFavoriteWatchface(application)
                }
                undoManager?.setActionName("Favorite Watchface")
            }
        )
        .navigationTitle("Apps")
        .task { await model.loadApplications() }
        .toolbar {
            ToolbarItem {
                Button("Add App", systemImage: "plus") {
                    isShowingCatalog = true
                }
            }
        }
        .sheet(isPresented: $isShowingCatalog) {
            CatalogView(
                model: model,
                isImportingApplication: model.isImportingApplication,
                isImportDisabled: model.isApplicationManagementBusy,
                importApplication: { isChoosingPackage = true }
            )
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let packageURL = urls.first(where: { $0.pathExtension.lowercased() == "pbw" }) else {
                return false
            }
            Task { await model.importApplication(from: packageURL) }
            return true
        }
        .confirmationDialog(
            "Remove this watch application?",
            isPresented: Binding(
                get: { pendingRemovalID != nil },
                set: { if !$0 { pendingRemovalID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Application", role: .destructive) {
                guard let applicationID = pendingRemovalID else { return }
                pendingRemovalID = nil
                Task { await model.removeApplication(id: applicationID) }
            }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        } message: {
            Text("The application and its settings will be removed from the connected Pebble.")
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
    /// nil when no watch is connected: install state is unknown, not shown.
    var installedApplicationIDs: Set<UUID>?
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
                        installedApplicationIDs: installedApplicationIDs,
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
                        installedApplicationIDs: installedApplicationIDs,
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
    var installedApplicationIDs: Set<UUID>?
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
                    isInstalled: installedApplicationIDs.map { $0.contains(application.id) },
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
                .contextMenu {
                    if application.isConfigurable {
                        Button("Configure", systemImage: "gearshape") {
                            configureApplication(application)
                        }
                    }
                    if application.kind == .watchface {
                        Button(activeWatchfaceID == application.id ? "Active" : "Activate", systemImage: "play.circle") {
                            activateWatchface(application)
                        }
                        .disabled(activeWatchfaceID == application.id)
                        Button(favoriteWatchfaceIDs.contains(application.id) ? "Remove Favorite" : "Favorite", systemImage: "star") {
                            toggleFavoriteWatchface(application)
                        }
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) {
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
    /// nil when no watch is connected.
    var isInstalled: Bool?
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
                if let isInstalled {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed on this watch", systemImage: "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .accessibilityElement(children: .contain)
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
    @State private var isAddingWatch = false

    // Saved watches plus any connected watch that has not been saved yet.
    private var listedWatchIDs: [String] {
        let savedIDs = model.savedWatches.map(\.id)
        let unsavedConnected = model.connections
            .map(\.device.id)
            .filter { !savedIDs.contains($0) }
        return unsavedConnected + savedIDs
    }

    var body: some View {
        List {
            if listedWatchIDs.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "applewatch")
                } description: {
                    Text("Add a Pebble 2 Duo, Pebble Time 2, or Pebble Round 2.")
                } actions: {
                    Button("Add Watch", systemImage: "plus") {
                        isAddingWatch = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Section("My Watches") {
                    ForEach(listedWatchIDs, id: \.self) { watchID in
                        NavigationLink {
                            WatchDetailView(model: model, watchID: watchID)
                        } label: {
                            WatchListRow(model: model, watchID: watchID)
                        }
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
                Button("Add Watch", systemImage: "plus") {
                    isAddingWatch = true
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(isPresented: $isAddingWatch) {
            AddWatchSheet(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pebbleScanRequested)) { _ in
            isAddingWatch = true
        }
    }
}

private struct AddWatchSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if case .failed(let error) = model.connectionState {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Bluetooth error: \(error.message)")
                }
                if let errorMessage = model.watchManagementErrorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                Section {
                    ForEach(model.discoveredDevices) { device in
                        DiscoveredDeviceRow(device: device) {
                            Task {
                                await model.connect(to: device)
                                if model.connections.contains(where: { $0.device.id == device.id }) {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(isConnecting)
                    }
                } header: {
                    HStack {
                        Text("Nearby")
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .navigationTitle("Add Watch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .task {
            // Scan for the whole lifetime of the sheet; the task is cancelled
            // when the sheet closes and the loop ends after the current pass.
            while !Task.isCancelled {
                await model.scan()
                if model.connections.isEmpty, case .failed = model.connectionState {
                    // Bluetooth is unavailable; retry slowly instead of spinning.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private var isConnecting: Bool {
        !model.connectingDeviceIDs.isEmpty
    }
}

private struct WatchListRow: View {
    var model: AppModel
    var watchID: String

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var savedWatch: SavedPebbleWatch? {
        model.savedWatches.first { $0.id == watchID }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                if let connection {
                    if let batteryLevel = connection.device.batteryLevel {
                        Text(batteryLevel, format: .percent)
                    }
                } else if let savedWatch {
                    Text(savedWatch.lastConnectedAt, format: .relative(presentation: .named))
                }
                
                switch connection?.phase {
                case .connected:
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Connected")
                    }
                    .foregroundStyle(.green)
                case .reconnecting:
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Reconnecting…")
                    }
                    .foregroundStyle(.orange)
                case .disconnected, nil:
                    HStack {
                        Image(systemName: "applewatch.slash")
                        Text("Not connected")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(connection?.device.name ?? savedWatch?.name ?? watchID)
            if let displayName = (connection?.device.model ?? savedWatch?.model)?.displayName {
                Text(displayName)
            }
        }
    }
}

private struct WatchDetailView: View {
    var model: AppModel
    var watchID: String
    @State private var isConfirmingForget = false
    @State private var pendingReset: PebbleResetKind?
    @Environment(\.dismiss) private var dismiss

    private var connection: WatchConnection? {
        model.connections.first { $0.device.id == watchID }
    }

    private var savedWatch: SavedPebbleWatch? {
        model.savedWatches.first { $0.id == watchID }
    }

    private var watchName: String {
        connection?.device.name ?? savedWatch?.name ?? watchID
    }

    var body: some View {
        Form {
            Section("Watch") {
                if let model = connection?.device.model ?? savedWatch?.model {
                    LabeledContent("Model", value: model.displayName)
                }
                if let firmwareVersion = connection?.device.firmwareVersion ?? savedWatch?.firmwareVersion {
                    LabeledContent("Firmware", value: firmwareVersion)
                }
                if let serialNumber = connection?.device.serialNumber ?? savedWatch?.serialNumber {
                    LabeledContent("Serial Number", value: serialNumber)
                }
                if let batteryLevel = connection?.device.batteryLevel ?? savedWatch?.lastBatteryLevel {
                    LabeledContent("Battery", value: batteryLevel, format: .percent)
                }
                LabeledContent("Status") {
                    switch connection?.phase {
                    case .connected:
                        Text("Connected")
                    case .reconnecting:
                        Text("Reconnecting…")
                    case .disconnected, nil:
                        Text("Not connected")
                    }
                }
            }
            Section("Connection") {
                if connection == nil, let savedWatch {
                    Button("Connect", systemImage: "applewatch.radiowaves.left.and.right") {
                        Task { await model.connect(to: savedWatch) }
                    }
                    .disabled(model.connectingDeviceIDs.contains(watchID))
                }
                if savedWatch != nil {
                    Toggle("Connect Automatically", isOn: Binding(
                        get: { savedWatch?.automaticallyConnects ?? false },
                        set: { enabled in
                            Task { await model.setAutomaticallyConnects(enabled, watchID: watchID) }
                        }
                    ))
                }
                if connection != nil {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnect(deviceID: watchID) }
                    }
                }
            }
            Section("Notifications") {
                Button("Send Test Notification", systemImage: "bell.badge") {
                    Task { await model.sendTestNotification(deviceID: watchID) }
                }
                .disabled(connection?.isConnected != true)
                if let notificationStatusMessage = model.notificationStatusMessage {
                    Label(notificationStatusMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Restart Watch", systemImage: "arrow.clockwise") {
                    pendingReset = .restart
                }
                .disabled(connection?.isConnected != true)
                Button("Restart into Recovery Firmware", systemImage: "lifepreserver") {
                    pendingReset = .recoveryFirmware
                }
                .disabled(connection?.isConnected != true)
                Button("Factory Reset", systemImage: "trash", role: .destructive) {
                    pendingReset = .factoryReset
                }
                .disabled(connection?.isConnected != true)
                if let watchResetStatusMessage = model.watchResetStatusMessage {
                    Label(watchResetStatusMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reset")
            } footer: {
                Text("The watch restarts without answering, so it disconnects immediately. A factory reset erases everything stored on the watch.")
            }
            Section {
                Button("Forget Watch", role: .destructive) {
                    isConfirmingForget = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(watchName)
        .confirmationDialog(
            "Forget \(watchName)?",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget Watch", role: .destructive) {
                Task {
                    await model.forgetWatch(id: watchID)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Automatic reconnection information for this Pebble will be removed.")
        }
        .confirmationDialog(
            "Reset \(watchName)?",
            isPresented: Binding(
                get: { pendingReset != nil },
                set: { if !$0 { pendingReset = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingReset
        ) { kind in
            Button(actionTitle(for: kind), role: kind == .factoryReset ? .destructive : nil) {
                pendingReset = nil
                Task { await model.resetWatch(kind, deviceID: watchID) }
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: { kind in
            Text(confirmationMessage(for: kind))
        }
    }

    private func actionTitle(for kind: PebbleResetKind) -> LocalizedStringKey {
        switch kind {
        case .restart: "Restart Watch"
        case .recoveryFirmware: "Restart into Recovery Firmware"
        case .factoryReset: "Erase Watch"
        }
    }

    private func confirmationMessage(for kind: PebbleResetKind) -> LocalizedStringKey {
        switch kind {
        case .restart:
            "The watch disconnects while it restarts."
        case .recoveryFirmware:
            "The watch restarts into recovery firmware, where only firmware updates are available."
        case .factoryReset:
            "Every app, watchface, and setting stored on the watch is erased. This cannot be undone."
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

private struct SettingsView: View {
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
                .disabled(model.connectedDevice == nil)
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

private enum FirmwareDestructiveAction: Identifiable {
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
        return url.scheme?.lowercased() == "https" ? .allow : .cancel
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
