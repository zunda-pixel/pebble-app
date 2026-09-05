import PebbleProtocol
import SwiftUI

struct TimelineRemindersView: View {
    var model: AppModel

    var body: some View {
        TimelineRemindersContent(
            reminders: model.reminders,
            feedback: model.reminderFeedback
        ) { removed in
            Task { await model.removeReminders(removed) }
        }
    }
}

/// Split at now: what is still coming is what the reader is looking for, and
/// the watch is told about that half only.
struct TimelineRemindersContent: View {
    var reminders: [TimelinePin]
    var feedback: FeatureFeedback?
    var remove: ([TimelinePin]) -> Void

    private var upcoming: [TimelinePin] {
        reminders.filter { $0.timestamp > .now }.sorted { $0.timestamp < $1.timestamp }
    }

    private var past: [TimelinePin] {
        reminders.filter { $0.timestamp <= .now }.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        List {
            if !upcoming.isEmpty {
                Section {
                    rows(upcoming)
                } header: {
                    Text("Coming Up")
                } footer: {
                    Text("What the phone's Reminders app has is here as well, and letting go of one here lets go of it there.")
                }
            }
            if !past.isEmpty {
                Section {
                    rows(past)
                } header: {
                    Text("Passed")
                } footer: {
                    Text("A reminder whose time has gone is not sent to the watch.")
                }
            }
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
            }
        }
        .overlay {
            if reminders.isEmpty {
                ContentUnavailableView(
                    "No Reminders",
                    systemImage: "bell.badge",
                    description: Text("Add one and the watch will buzz when its time comes.")
                )
            }
        }
    }

    private func rows(_ reminders: [TimelinePin]) -> some View {
        ForEach(reminders) { reminder in
            LabeledContent(reminder.title) {
                Text(reminder.timestamp, format: .dateTime.month().day().hour().minute())
            }
        }
        .onDelete { offsets in
            // These rows are one half of the list, sorted their own way.
            remove(offsets.compactMap { reminders.indices.contains($0) ? reminders[$0] : nil })
        }
    }
}

#Preview("Reminders") {
    NavigationStack {
        TimelineRemindersContent(
            reminders: PreviewSamples.reminders,
            feedback: nil
        ) { _ in }
    }
}

#Preview("No reminders") {
    NavigationStack {
        TimelineRemindersContent(reminders: [], feedback: nil) { _ in }
    }
}
