import API
import SwiftUI

struct TimelinePinsView: View {
    var model: AppModel

    var body: some View {
        TimelinePinsContent(
            pins: model.timelinePins,
            statusMessage: model.timelineActionStatusMessage
        ) { removed in
            Task { await model.removeTimelinePins(removed) }
        }
    }
}

/// The list is as long as the reader's diary — one calendar sync brings a
/// month of events — so it is grouped and searchable.
struct TimelinePinsContent: View {
    var pins: [PebbleTimelinePin]
    var statusMessage: LocalizedStringKey?
    var remove: ([PebbleTimelinePin]) -> Void

    @State private var search = ""

    private var matches: [PebbleTimelinePin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pins }
        return pins.filter { $0.title.localizedCaseInsensitiveContains(query) }
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
                            if pin.isAllDay {
                                Text("All Day")
                            } else {
                                Text(pin.timestamp, format: .dateTime.hour().minute())
                            }
                        }
                    }
                    .onDelete { offsets in
                        // The rows here are one day's worth of what a search left, and say nothing
                        // about their place in the whole list.
                        remove(offsets.compactMap { day.pins.indices.contains($0) ? day.pins[$0] : nil })
                    }
                } header: {
                    Text(day.date, format: .dateTime.year().month().day())
                }
            }
            if let statusMessage {
                Section {
                    Text(statusMessage).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $search)
        .overlay {
            if pins.isEmpty {
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

#Preview("Pins") {
    NavigationStack {
        TimelinePinsContent(
            pins: PreviewSamples.pins,
            statusMessage: "Pebble 5209 snoozed a pin."
        ) { _ in }
    }
}

#Preview("No pins") {
    NavigationStack {
        TimelinePinsContent(pins: [], statusMessage: nil) { _ in }
    }
}
