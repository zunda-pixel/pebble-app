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

enum AppSection: String, CaseIterable, Identifiable {
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

struct AppRootView: View {
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
struct MacRootView: View {
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
struct IOSRootView: View {
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

struct OnboardingView: View {
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

struct ConnectionStatusBanner: View {
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

struct SectionContent: View {
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
