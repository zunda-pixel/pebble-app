import PebbleProtocol
import SwiftUI

struct NotificationHistoryView: View {
    var model: AppModel

    var body: some View {
        NotificationHistoryContent(
            notifications: model.notifications.sent,
            feedback: model.notifications.historyFeedback,
            forget: { Task { await model.forgetSentNotifications() } }
        )
    }
}

/// What this app has sent to a watch.
struct NotificationHistoryContent: View {
    var notifications: [SentNotification]
    /// The answer to clearing the list. There was nowhere to put one, so a
    /// clear that failed emptied the screen and said nothing (#111).
    var feedback: FeatureFeedback?
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

            // Beside the button that asked, and inside the same condition: a
            // clear that worked leaves nothing to clear, so this section goes
            // with the entries. A clear that failed leaves them, and the
            // answer with them.
            if !notifications.isEmpty {
                Section {
                    Button("Clear History", role: .destructive, action: forget)
                    FeedbackBanner(feedback: feedback)
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
            feedback: nil,
            forget: {}
        )
    }
}

#Preview("Nothing sent") {
    NavigationStack {
        NotificationHistoryContent(notifications: [], feedback: nil, forget: {})
    }
}

#Preview("The history could not be cleared") {
    NavigationStack {
        // The entries are still there, which is the point: the file still
        // holds them, so the screen still shows them.
        NotificationHistoryContent(
            notifications: PreviewSamples.sentNotifications,
            feedback: .failure("The history could not be cleared."),
            forget: {}
        )
    }
}
