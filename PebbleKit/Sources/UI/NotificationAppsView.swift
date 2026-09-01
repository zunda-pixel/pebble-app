import API
import SwiftUI

/// The list is as long as the reader's phone is busy, so it is searchable
/// rather than one run of rows.
struct NotificationAppsView: View {
    var model: AppModel
    @State private var search = ""

    private var matches: [NotificationSourceApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.notificationSourceApps }
        return model.notificationSourceApps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(matches) { app in
                    NavigationLink {
                        NotificationAppView(model: model, app: app)
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
                    let removed = offsets.compactMap { matches.indices.contains($0) ? matches[$0] : nil }
                    Task { await model.removeNotificationSourceApps(removed) }
                }
            } footer: {
                Text("Apps the watch has seen sending notifications. Muting one tells the watch to filter that app's notifications.")
            }
        }
        .searchable(text: $search)
        .overlay {
            if model.notificationSourceApps.isEmpty {
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
