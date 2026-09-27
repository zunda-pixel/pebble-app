import SwiftUI

/// How the phone's Reminders app reaches the watch.
struct RemindersSettingsView: View {
    var model: AppModel

    var body: some View {
        RemindersSettingsContent(
            allDayReminderMinutes: model.timeline.allDayReminderMinutes,
            setAllDayReminderMinutes: { minutes in
                Task { await model.setAllDayReminderTime(minutes: minutes) }
            }
        )
    }
}

struct RemindersSettingsContent: View {
    var allDayReminderMinutes: Int
    var setAllDayReminderMinutes: (Int) -> Void

    /// Today at that time, for a picker that only shows the hour and minute.
    private var allDayReminderTime: Binding<Date> {
        Binding(
            get: {
                let midnight = Calendar.current.startOfDay(for: .now)
                return midnight.addingTimeInterval(TimeInterval(allDayReminderMinutes * 60))
            },
            set: { date in
                let time = Calendar.current.dateComponents([.hour, .minute], from: date)
                setAllDayReminderMinutes((time.hour ?? 0) * 60 + (time.minute ?? 0))
            }
        )
    }

    var body: some View {
        Form {
            Section {
                DatePicker(
                    "All-Day Reminders",
                    selection: allDayReminderTime,
                    displayedComponents: .hourAndMinute
                )
            } footer: {
                Text("A reminder with a date and no time buzzes on the watch at this time. The Reminders app tells of one at the time chosen for Today Notification in Settings, which this app cannot read, so choose the same time here.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text("Reminder Settings"))
    }
}

#Preview("The Reminders app's own default") {
    NavigationStack {
        RemindersSettingsContent(allDayReminderMinutes: 9 * 60, setAllDayReminderMinutes: { _ in })
    }
}

#Preview("An early riser") {
    NavigationStack {
        RemindersSettingsContent(allDayReminderMinutes: 6 * 60 + 30, setAllDayReminderMinutes: { _ in })
    }
}
