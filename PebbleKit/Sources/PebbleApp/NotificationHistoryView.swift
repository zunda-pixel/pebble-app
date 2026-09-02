import PebbleProtocol
import SwiftUI

struct NotificationHistoryView: View {
    var model: AppModel

    var body: some View {
        NotificationHistoryContent(
            notifications: model.sentNotifications,
            forget: { Task { await model.forgetSentNotifications() } }
        )
    }
}

/// What this app has sent to a watch.
struct NotificationHistoryContent: View {
    var notifications: [SentNotification]
    var forget: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(notifications) { notification in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: notification.title)
                        if !notification.body.isEmpty {
                            Text(verbatim: notification.body)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(notification.sentAt, format: .dateTime.month().day().hour().minute())
                            if !notification.watchNames.isEmpty {
                                Text(verbatim: notification.watchNames.formatted(.list(type: .and)))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                // Otherwise the list looks broken: the reader's phone has been
                // buzzing the watch all day and this shows three rows.
                Text("Only what this app sent. Notifications from your other apps go from iOS to the watch directly, and no app on the phone is shown what is in them.")
            }

            if !notifications.isEmpty {
                Section {
                    Button("Clear History", role: .destructive, action: forget)
                }
            }
        }
        .overlay {
            if notifications.isEmpty {
                ContentUnavailableView(
                    "Nothing Sent Yet",
                    systemImage: "bell.badge",
                    description: Text("Watch app notifications and test notifications appear here once one has gone out.")
                )
            }
        }
        .navigationTitle(Text("Sent Notifications"))
    }
}

#Preview("History") {
    NavigationStack {
        NotificationHistoryContent(
            notifications: PreviewSamples.sentNotifications,
            forget: {}
        )
    }
}

#Preview("Nothing sent") {
    NavigationStack {
        NotificationHistoryContent(notifications: [], forget: {})
    }
}
