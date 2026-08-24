public import SwiftUI
public import API
import UniformTypeIdentifiers

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
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case apps
    case health
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .devices:
            "Devices"
        case .apps:
            "Apps"
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
        case .health:
            "heart"
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
        case .health:
            PlaceholderView(
                title: "Health",
                description: "Health synchronization will be available after the local sync foundation is complete.",
                systemImage: "heart"
            )
        case .settings:
            SettingsView()
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
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var removeApplication: (UUID) -> Void
    var reorderApplications: (PebbleApplicationKind, IndexSet, Int) -> Void

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
                        removeApplication: removeApplication,
                        moveApplications: { offsets, destination in
                            reorderApplications(.watchapp, offsets, destination)
                        }
                    )
                }
                if !watchfaces.isEmpty {
                    ApplicationSection(
                        title: "Watchfaces",
                        applications: watchfaces,
                        removeApplication: removeApplication,
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
    var removeApplication: (UUID) -> Void
    var moveApplications: (IndexSet, Int) -> Void

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationRow(
                    name: application.displayName,
                    companyName: application.companyName,
                    versionLabel: application.versionLabel,
                    kind: application.kind
                )
                .swipeActions {
                    Button("Remove", role: .destructive) {
                        removeApplication(application.id)
                    }
                }
            }
            .onMove(perform: moveApplications)
        }
    }
}

private struct ApplicationRow: View {
    var name: String
    var companyName: String
    var versionLabel: String
    var kind: PebbleApplicationKind

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
        }
        .navigationTitle("Devices")
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
    var body: some View {
        Form {
            Section("Support") {
                LabeledContent("Supported Watches", value: "3 models")
                LabeledContent("Connection", value: "Bluetooth LE")
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    ContentView(client: MockPebbleClient())
}
