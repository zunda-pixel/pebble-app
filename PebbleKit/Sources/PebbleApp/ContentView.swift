public import SwiftUI

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
            "Watches"
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
