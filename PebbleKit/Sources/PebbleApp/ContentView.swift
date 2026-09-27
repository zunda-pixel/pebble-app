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
public func makeDefaultPebbleClient() -> any WatchClient {
    CoreBluetoothWatchClient()
}

// The restoration identifier has to be stable and unique per watch, or iOS
// hands one client another's restored state.
@MainActor
public func makeDefaultWatchClientFactory() -> @MainActor (WatchID) -> any WatchClient {
    { watchID in
        CoreBluetoothWatchClient(restoreIdentifier: "dev.pebble.central.watch.\(watchID)")
    }
}

#if os(macOS)
@MainActor
public func makeQEMUWatchClient() -> any WatchClient {
    QEMUWatchClient()
}
#endif

public struct ContentView: View {
    var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    public init(model: AppModel) {
        self.model = model
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

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case watches
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
        case .watches:
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

    /// Looked up in this module's catalogue. A `Button(section.title)` in the
    /// app target resolves the key against the app's own, which has none of
    /// these.
    public var titleText: Text {
        Text(title)
    }

    public var keyboardShortcut: KeyEquivalent {
        switch self {
        case .watches: "1"
        case .apps: "2"
        case .timeline: "3"
        case .health: "4"
        case .settings: ","
        }
    }

    public var systemImage: String {
        switch self {
        case .watches:
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
    @Default(.hasCompletedWatchSetup) private var hasCompletedWatchSetup
    @State private var setup: WatchSetupContext?
    @State private var window = UUID()
#if os(macOS)
    @Environment(\.appearsActive) private var appearsActive
#endif

    /// Whether this window is the one that shows what the model asks for.
    private var isFront: Bool {
        FrontWindow.shared.isFront(window)
    }

    /// Something the model has asked every window to show is up. The window
    /// showing it keeps it while the reader clicks elsewhere: handed to the
    /// window clicked, it would vanish from under them and come up again there.
    private var isShowingModelPresentation: Bool {
        model.deepLinks.pendingPackage != nil
            || model.deepLinks.storeApplication != nil
            || model.deepLinks.feedback != nil
    }

    var body: some View {
        Group {
#if os(macOS)
            MacRootView(model: model, isFront: isFront)
#else
            IOSRootView(model: model, isFront: isFront)
#endif
        }
        .environment(\.windowIdentity, window)
        .onAppear { FrontWindow.shared.bringForward(window) }
        .onDisappear { FrontWindow.shared.close(window) }
#if os(macOS)
        .onChange(of: appearsActive) { _, active in
            guard active, !isShowingModelPresentation else { return }
            FrontWindow.shared.bringForward(window)
        }
        .onChange(of: isShowingModelPresentation) { _, showing in
            guard !showing, appearsActive else { return }
            FrontWindow.shared.bringForward(window)
        }
#endif
        // The permissions are read here rather than in the sheet, so that the
        // steps cannot be decided before the answers are known.
        .onChange(of: model.connections.filter(\.isConnected).map(\.watch.id)) { _, connectedIDs in
            guard isFront, !hasCompletedWatchSetup, setup == nil, let watchID = connectedIDs.first else {
                return
            }
            setup = WatchSetupContext(watchID: watchID, permissions: .current())
        }
        // Asked once, however it was left: Settings is where the rest of the
        // answers live.
        .sheet(item: $setup, onDismiss: { hasCompletedWatchSetup = true }) { context in
            WatchSetupSheet(model: model, context: context) {
                setup = nil
            }
        }
        .onOpenURL { url in
            Task { await model.openDeepLink(url) }
        }
        // Dismissing is the reader's answer too: the copy is deleted either way.
        .sheet(item: Binding(
            get: { isFront ? model.deepLinks.pendingPackage : nil },
            set: { if $0 == nil, isFront { model.dismissPendingDeepLinkPackage() } }
        )) { pending in
            DeepLinkPackageSheet(
                package: pending,
                install: { Task { await model.confirmPendingDeepLinkPackage() } },
                cancel: { model.dismissPendingDeepLinkPackage() }
            )
        }
        .sheet(item: Binding(
            get: { isFront ? model.deepLinks.storeApplication : nil },
            set: { if $0 == nil, isFront { model.dismissDeepLinkStoreApplication() } }
        )) { application in
            NavigationStack {
                CatalogApplicationDetailView(
                    application: application,
                    model: model,
                    editGlance: nil
                )
                .toolbar {
                    Button(role: .close) { model.dismissDeepLinkStoreApplication() }
                }
            }
        }
        .alert(
            Text("The link could not be opened."),
            isPresented: Binding(
                get: { isFront && model.deepLinks.feedback != nil },
                set: { if !$0, isFront { model.clearDeepLinkFeedback() } }
            ),
            presenting: model.deepLinks.feedback
        ) { _ in } message: { feedback in
            Text(feedback.message)
        }
    }
}

#if os(macOS)
struct MacRootView: View {
    var model: AppModel
    var isFront: Bool
    @State private var selection: AppSection? = .watches

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
                    SectionContent(section: selection ?? .watches, model: model)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onWindowMessage(ScanRequest.self, from: model) { _ in
            selection = .watches
        }
        .onWindowMessage(SectionRequest.self, from: model) { message in
            selection = message.section
        }
        // A deep link's navigation. Settings is its own window on the Mac and
        // not in the sidebar, so that one request has nowhere to go here.
        // Asked of the front window alone, which takes it up once it is front.
        .onChange(of: isFront ? model.deepLinks.requestedSection : nil, initial: true) { _, requested in
            guard let requested else { return }
            if requested != .settings { selection = requested }
            model.consumeRequestedDeepLinkSection()
        }
    }
}
#else
struct IOSRootView: View {
    var model: AppModel
    var isFront: Bool
    @State private var selection: AppSection = .watches

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppSection.allCases) { section in
                // The label as a view rather than a key: `Tab`'s own
                // title initializer and a shimmed one cannot be told apart,
                // and this way the label is built by `Label` above.
                Tab(value: section) {
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
        // `initial:` because a cold start from a link sets the request before
        // this view exists, and waiting for a change would wait forever.
        .onChange(of: isFront ? model.deepLinks.requestedSection : nil, initial: true) { _, requested in
            guard let requested else { return }
            selection = requested
            model.consumeRequestedDeepLinkSection()
        }
    }
}
#endif

struct ConnectionStatusBanner: View {
    var state: WatchConnectionState
    var cancelReconnect: (() -> Void)? = nil
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack {
            Label { title } icon: { Image(systemName: systemImage) }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Connection status"))
                .accessibilityValue(title)
            if case .reconnecting = state, let cancelReconnect {
                Button("Stop Reconnecting", role: .cancel, action: cancelReconnect)
                    .font(.callout)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
    }

    // A `Text` rather than a key: the failure reads as two sentences, and one of
    // them comes from the connection layer already localized.
    private var title: Text {
        switch state {
        case .idle: Text("Not connected")
        case .scanning: Text("Scanning for watches…")
        case .connecting: Text("Connecting…")
        case .negotiating: Text("Setting up connection…")
        case .connected(let watch): Text("Connected to \(watch.name)")
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
        case .watches:
            WatchesView(model: model)
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
    ConnectionStatusBanner(state: .reconnecting(watchID: PreviewSamples.watch.id)) {}
}

#Preview("Connected") {
    ConnectionStatusBanner(state: .connected(PreviewSamples.watch))
}

#Preview("Failed") {
    ConnectionStatusBanner(state: .failed(.connectionTimedOut))
}

#Preview("Not connected") {
    ConnectionStatusBanner(state: .idle)
}

#Preview("Scanning") {
    ConnectionStatusBanner(state: .scanning)
}

#Preview("Root") {
    AppRootView(model: PreviewSamples.appModel())
}
