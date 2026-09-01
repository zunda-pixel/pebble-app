import SwiftUI
import API

struct TimelineView: View {
    var model: AppModel
    @State private var title = ""
    @State private var date = Date()
    @State private var reminderTitle = ""
    @State private var reminderDate = Date()

    var body: some View {
        List {
            Section("New Pin") {
                TextField("Title", text: $title)
                DatePicker("Date", selection: $date)
                Button("Add to Timeline", systemImage: "plus") {
                    let value = title
                    title = ""
                    Task { await model.addTimelinePin(title: value, date: date) }
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                NavigationLink {
                    TimelinePinsView(model: model)
                } label: {
                    LabeledContent("Pins") {
                        Text("\(model.timelinePins.count) pins")
                    }
                }
            } footer: {
                Text("Everything the watch is showing on its timeline, including the events a calendar sync brought over.")
            }
            Section {
                TextField("Title", text: $reminderTitle)
                DatePicker("Time", selection: $reminderDate)
                Button("Add Reminder", systemImage: "bell.badge") {
                    let value = reminderTitle
                    reminderTitle = ""
                    Task { await model.addReminder(title: value, date: reminderDate) }
                }
                .disabled(reminderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(model.reminders) { reminder in
                    LabeledContent(reminder.title) {
                        Text(reminder.timestamp, format: .dateTime)
                    }
                }
                .onDelete { offsets in Task { await model.removeReminders(at: offsets) } }
                if let message = model.reminderStatusMessage {
                    Text(message).foregroundStyle(.secondary)
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("A reminder buzzes on the watch when its time comes, rather than waiting on the timeline. The watch keeps the ones near today and forgets the rest.")
            }
            Section("Calendar") {
                Button("Sync Calendar", systemImage: "calendar.badge.clock") {
                    Task { await model.synchronizeCalendar() }
                }
            }
        }
        .navigationTitle("Timeline")
        .task {
            await model.loadTimeline()
            await model.loadReminders()
        }
    }
}
