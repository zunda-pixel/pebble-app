import API
import SwiftUI

/// The reminders the watch buzzes for.
///
/// Split at now: what is still coming is what the reader is looking for, and
/// what has passed is only there to be tidied away. The watch is told about the
/// first group and not the second.
struct TimelineRemindersView: View {
    var model: AppModel

    private var upcoming: [PebbleTimelinePin] {
        model.reminders.filter { $0.timestamp > .now }.sorted { $0.timestamp < $1.timestamp }
    }

    private var past: [PebbleTimelinePin] {
        model.reminders.filter { $0.timestamp <= .now }.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        List {
            if !upcoming.isEmpty {
                Section {
                    rows(upcoming)
                } header: {
                    Text("Coming Up")
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
            if let message = model.reminderStatusMessage {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.reminders.isEmpty {
                ContentUnavailableView(
                    "No Reminders",
                    systemImage: "bell.badge",
                    description: Text("Add one and the watch will buzz when its time comes.")
                )
            }
        }
    }

    private func rows(_ reminders: [PebbleTimelinePin]) -> some View {
        ForEach(reminders) { reminder in
            LabeledContent(reminder.title) {
                Text(reminder.timestamp, format: .dateTime.month().day().hour().minute())
            }
        }
        .onDelete { offsets in
            // Named rather than counted: these rows are one half of the list,
            // sorted their own way.
            let removed = offsets.compactMap { reminders.indices.contains($0) ? reminders[$0] : nil }
            Task { await model.removeReminders(removed) }
        }
    }
}
