import Defaults
import SwiftUI

/// Which calendars reach the watch's timeline, and how.
struct CalendarSettingsView: View {
    var model: AppModel

    var body: some View {
        CalendarSettingsContent(
            calendars: model.timeline.calendars,
            isCalendarEnabled: { model.isCalendarEnabled($0) },
            setCalendarEnabled: { calendar, isEnabled in
                Task { await model.setCalendarEnabled(calendar, isEnabled) }
            },
            setPinsEnabled: { enabled in
                Task { await model.setCalendarPinsEnabled(enabled) }
            },
            setIncludesDeclined: { included in
                Task { await model.setCalendarIncludesDeclined(included) }
            }
        )
        // Opening this screen is the reader asking about calendars, which is
        // the moment reading them — and prompting, on a phone that was never
        // asked — is warranted.
        .task { await model.loadCalendars() }
    }
}

struct CalendarSettingsContent: View {
    var calendars: [PhoneCalendar]
    var isCalendarEnabled: (PhoneCalendar) -> Bool
    var setCalendarEnabled: (PhoneCalendar, Bool) -> Void
    var setPinsEnabled: (Bool) -> Void = { _ in }
    var setIncludesDeclined: (Bool) -> Void = { _ in }

    @Default(.calendarPinsEnabled) private var pinsEnabled
    @Default(.calendarIncludesDeclined) private var includesDeclined
    // The stored preferences, observed so the rows move when the model writes
    // them — the row's own value comes through `isCalendarEnabled`, which
    // resolves reissued identifiers the same way the sync does.
    @Default(.calendarPreferences) private var preferences

    /// Grouped the way the phone's own Calendar app groups them: by account.
    private var sources: [(title: String, calendars: [PhoneCalendar])] {
        var order: [String] = []
        var grouped: [String: [PhoneCalendar]] = [:]
        for calendar in calendars {
            if grouped[calendar.sourceTitle] == nil { order.append(calendar.sourceTitle) }
            grouped[calendar.sourceTitle, default: []].append(calendar)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Calendar on the Timeline", isOn: Binding(
                    get: { pinsEnabled },
                    set: { setPinsEnabled($0) }
                ))
                Toggle("Include Declined Events", isOn: Binding(
                    get: { includesDeclined },
                    set: { setIncludesDeclined($0) }
                ))
            } footer: {
                Text("Events from the calendars below appear on the watch's timeline for the next 30 days. Turning a calendar off takes its events off the watch as well.")
            }
            ForEach(sources, id: \.title) { source in
                Section(source.title) {
                    ForEach(source.calendars) { calendar in
                        Toggle(isOn: Binding(
                            get: {
                                // Reading `preferences` keeps the rows live;
                                // the resolution itself is the model's.
                                _ = preferences
                                return isCalendarEnabled(calendar)
                            },
                            set: { setCalendarEnabled(calendar, $0) }
                        )) {
                            Text(verbatim: calendar.title)
                        }
                        .disabled(!pinsEnabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Calendars"))
    }
}

#Preview("Two accounts") {
    NavigationStack {
        CalendarSettingsContent(
            calendars: [
                PhoneCalendar(id: "1", title: "仕事", sourceTitle: "iCloud"),
                PhoneCalendar(id: "2", title: "家族", sourceTitle: "iCloud"),
                PhoneCalendar(id: "3", title: "祝日", sourceTitle: "その他"),
            ],
            isCalendarEnabled: { $0.id != "3" },
            setCalendarEnabled: { _, _ in }
        )
    }
}
