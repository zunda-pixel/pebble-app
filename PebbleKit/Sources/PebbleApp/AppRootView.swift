import Defaults
import SwiftUI
import PebbleProtocol

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
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { model.dismissDeepLinkStoreApplication() }
                    }
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

#Preview("Root") {
    AppRootView(model: PreviewSamples.appModel())
}
