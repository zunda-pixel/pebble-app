import Defaults
public import SwiftUI
public import PebbleProtocol
import PebbleTransport
import Charts
import UniformTypeIdentifiers
import WebKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
public func makeDefaultPebbleClient() -> any PebbleClient {
    CoreBluetoothPebbleClient()
}

// The restoration identifier has to be stable and unique per watch, or iOS
// hands one client another's restored state.
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

public enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case apps
    case timeline
    case health
    case settings

    public static var windowSections: [AppSection] {
        allCases.filter { $0 != .settings }
    }

    public var id: Self { self }

    public var title: LocalizedStringKey {
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

    public var keyboardShortcut: KeyEquivalent {
        switch self {
        case .devices: "1"
        case .apps: "2"
        case .timeline: "3"
        case .health: "4"
        case .settings: ","
        }
    }

    public var systemImage: String {
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
    @Default(.hasCompletedOnboarding) private var hasCompletedOnboarding

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
            List(AppSection.windowSections, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle(Text("Pebble"))
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
        .onPebbleMessage(PebbleScanRequest.self, from: model) { _ in
            selection = .devices
        }
        .onPebbleMessage(PebbleSectionRequest.self, from: model) { message in
            selection = message.section
        }
    }
}
#else
struct IOSRootView: View {
    var model: AppModel

    var body: some View {
        TabView {
            ForEach(AppSection.allCases) { section in
                // The label as a view rather than a key: `Tab`'s own
                // title initializer and a shimmed one cannot be told apart,
                // and this way the label is built by `Label` above.
                Tab {
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
                } label: {
                    Label(section.title, systemImage: section.systemImage)
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
            Label { title } icon: { Image(systemName: systemImage) }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if case .reconnecting = state, let cancelReconnect {
                Button("Cancel", role: .cancel, action: cancelReconnect)
                    .font(.callout)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
        .accessibilityLabel(Text("Connection status"))
        .accessibilityValue(title)
    }

    // A `Text` rather than a key: the failure reads as two sentences, and one of
    // them comes from the connection layer already localized.
    private var title: Text {
        switch state {
        case .idle: Text("Not connected")
        case .scanning: Text("Scanning for watches…")
        case .connecting: Text("Connecting…")
        case .negotiating: Text("Setting up connection…")
        case .connected(let device): Text("Connected to \(device.name)")
        case .reconnecting: Text("Connection lost — reconnecting…")
        case .failed(let error): Text("Connection failed. \(Text(error.message))")
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

#Preview("Reconnecting") {
    ConnectionStatusBanner(state: .reconnecting(deviceID: PreviewSamples.watch.id)) {}
}

#Preview("Connected") {
    ConnectionStatusBanner(state: .connected(PreviewSamples.watch))
}

#Preview("Onboarding") {
    OnboardingView {}
}

#Preview("Root") {
    AppRootView(model: PreviewSamples.appModel())
}
