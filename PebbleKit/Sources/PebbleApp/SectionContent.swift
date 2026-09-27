import SwiftUI

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

#Preview("Watches") {
    NavigationStack {
        SectionContent(section: .watches, model: PreviewSamples.appModel())
    }
}
