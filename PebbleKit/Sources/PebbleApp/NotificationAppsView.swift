import PebbleProtocol
import SwiftUI

struct NotificationAppsView: View {
    var model: AppModel

    var body: some View {
        NotificationAppsContent(
            apps: model.notificationSourceApps,
            remove: { removed in
                Task { await model.removeNotificationSourceApps(removed) }
            },
            destination: { app in
                NotificationAppView(model: model, app: app)
            }
        )
    }
}

/// The list is as long as the reader's phone is busy, so it is searchable
/// rather than one run of rows.
struct NotificationAppsContent<Destination: View>: View {
    var apps: [NotificationSourceApp]
    var remove: ([NotificationSourceApp]) -> Void
    @ViewBuilder var destination: (NotificationSourceApp) -> Destination

    @State private var search = ""

    private var matches: [NotificationSourceApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(matches) { app in
                    NavigationLink {
                        destination(app)
                    } label: {
                        LabeledContent {
                            Text(app.muteState.title)
                        } label: {
                            Text(verbatim: app.displayName)
                        }
                    }
                }
                .onDelete { offsets in
                    // The rows on screen are the ones a search left.
                    remove(offsets.compactMap { matches.indices.contains($0) ? matches[$0] : nil })
                }
            } footer: {
                Text("Apps the watch has seen sending notifications. Muting one tells the watch to filter that app's notifications.")
            }
        }
        .searchable(text: $search)
        .overlay {
            if apps.isEmpty {
                ContentUnavailableView(
                    "No Apps Yet",
                    systemImage: "app.badge",
                    description: Text("The watch adds an app here the first time it sees a notification from it.")
                )
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Phone App Notifications")
    }
}

#Preview("Apps") {
    NavigationStack {
        NotificationAppsContent(
            apps: PreviewSamples.notificationApps,
            remove: { _ in },
            destination: { app in Text(verbatim: app.bundleID) }
        )
    }
}

#Preview("No apps") {
    NavigationStack {
        NotificationAppsContent(
            apps: [],
            remove: { _ in },
            destination: { _ in EmptyView() }
        )
    }
}
