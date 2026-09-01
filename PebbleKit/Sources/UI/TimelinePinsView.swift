import API
import SwiftUI

/// The list is as long as the reader's diary — one calendar sync brings a
/// month of events — so it is grouped and searchable.
struct TimelinePinsView: View {
    var model: AppModel
    @State private var search = ""

    private var matches: [PebbleTimelinePin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.timelinePins }
        return model.timelinePins.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var days: [(date: Date, pins: [PebbleTimelinePin])] {
        let calendar = Calendar.current
        return Dictionary(grouping: matches) { calendar.startOfDay(for: $0.timestamp) }
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, pins: $0.value.sorted { $0.timestamp < $1.timestamp }) }
    }

    var body: some View {
        List {
            ForEach(days, id: \.date) { day in
                Section {
                    ForEach(day.pins) { pin in
                        LabeledContent(pin.title) {
                            Text(pin.timestamp, format: pin.isAllDay ? .dateTime.day() : .dateTime.hour().minute())
                        }
                    }
                    .onDelete { offsets in
                        // The rows here are one day's worth of what a search left, and say nothing
                        // about their place in the whole list.
                        let removed = offsets.compactMap { day.pins.indices.contains($0) ? day.pins[$0] : nil }
                        Task { await model.removeTimelinePins(removed) }
                    }
                } header: {
                    Text(day.date, format: .dateTime.year().month().day())
                }
            }
            if let message = model.timelineActionStatusMessage {
                Section {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search)
        .overlay {
            if model.timelinePins.isEmpty {
                ContentUnavailableView(
                    "No Pins",
                    systemImage: "pin",
                    description: Text("Add one with the plus button, or sync the calendar.")
                )
            } else if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
    }
}
