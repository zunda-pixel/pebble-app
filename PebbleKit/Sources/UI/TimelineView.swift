import SwiftUI
import API

struct TimelineView: View {
    var model: AppModel
    @State private var title = ""
    @State private var date = Date()

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
            Section("Pins") {
                ForEach(model.timelinePins) { pin in
                    LabeledContent(pin.title) { Text(pin.timestamp, format: .dateTime) }
                }
                .onDelete { offsets in Task { await model.removeTimelinePins(at: offsets) } }
            }
            if let message = model.timelineActionStatusMessage {
                Text(message).foregroundStyle(.secondary)
            }
            Section("Calendar") {
                Button("Sync Calendar", systemImage: "calendar.badge.clock") {
                    Task { await model.synchronizeCalendar() }
                }
            }
        }
        .navigationTitle("Timeline")
        .task { await model.loadTimeline() }
    }
}
