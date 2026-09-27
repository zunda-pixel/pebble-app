import PebbleProtocol
import SwiftUI

struct TimelinePinsView: View {
    var model: AppModel

    var body: some View {
        TimelinePinsContent(
            pins: model.timeline.pins,
            feedback: model.timeline.feedback
        ) { removed in
            Task { await model.removeTimelinePins(removed) }
        }
    }
}

/// The list is as long as the reader's diary — one calendar sync brings a
/// month of events — so it is grouped and searchable.
struct TimelinePinsContent: View {
    var pins: [TimelinePin]
    var feedback: FeatureFeedback?
    var remove: ([TimelinePin]) -> Void

    @State private var search = ""

    private var matches: [TimelinePin] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return pins }
        return pins.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var days: [(date: Date, pins: [TimelinePin])] {
        Dictionary(grouping: matches, by: Self.day(of:))
            .sorted { $0.key < $1.key }
            .map { (date: $0.key, pins: $0.value.sorted(by: Self.isOrderedBefore)) }
    }

    /// All-day pins head their day: their UTC-midnight timestamp is some
    /// arbitrary hour of the local day, and would put them among the timed ones.
    private static func isOrderedBefore(_ first: TimelinePin, _ second: TimelinePin) -> Bool {
        if first.isAllDay != second.isAllDay { return first.isAllDay }
        return first.timestamp < second.timestamp
    }

    /// The local midnight of the day a pin belongs to. An all-day pin's
    /// timestamp is UTC midnight of its date (`CalendarBridge.anchoredToUTCMidnight`),
    /// so its date is read in UTC; read locally it lands on the day before
    /// anywhere west of Greenwich.
    static func day(of pin: TimelinePin) -> Date {
        let local = Calendar.current
        guard pin.isAllDay else { return local.startOfDay(for: pin.timestamp) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let date = utc.dateComponents([.year, .month, .day], from: pin.timestamp)
        return local.date(from: date) ?? local.startOfDay(for: pin.timestamp)
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
            if feedback != nil {
                Section { FeedbackBanner(feedback: feedback) }
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
            feedback: .success("Pebble 5209 snoozed a pin.")
        ) { _ in }
    }
}

#Preview("No pins") {
    NavigationStack {
        TimelinePinsContent(pins: [], feedback: nil) { _ in }
    }
}
