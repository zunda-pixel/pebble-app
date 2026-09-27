import PebbleProtocol
import SwiftUI

/// Two databases on the watch and two behaviours, but one question for the
/// reader — what is coming up — so they share a screen.
enum TimelineListKind: String, CaseIterable, Identifiable {
    case pins
    case reminders

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .pins: "Pins"
        case .reminders: "Reminders"
        }
    }

    var newTitle: LocalizedStringKey {
        switch self {
        case .pins: "New Pin"
        case .reminders: "New Reminder"
        }
    }

    var symbol: String {
        switch self {
        case .pins: "pin"
        case .reminders: "bell.badge"
        }
    }
}

struct TimelineView: View {
    var model: AppModel
    @State private var kind = TimelineListKind.pins
    @State private var composing: TimelineListKind?
    @State private var showsCalendarSettings = false
    @State private var showsRemindersSettings = false

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("List", selection: $kind) {
                        ForEach(TimelineListKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(TimelineListKind.allCases) { kind in
                            Button(kind.newTitle, systemImage: kind.symbol) {
                                composing = kind
                            }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                // Each list is filled from its own app on the phone, and
                // asking reads that one rather than both. One ToolbarItem per
                // button: the phone's navigation bar shows an item's first
                // view and quietly drops the rest.
                switch kind {
                case .pins:
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Sync Calendar", systemImage: "calendar.badge.clock") {
                            Task { await model.synchronizeCalendar() }
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Calendars", systemImage: "calendar") {
                            showsCalendarSettings = true
                        }
                    }
                case .reminders:
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Sync Reminders", systemImage: "checklist") {
                            Task { await model.synchronizeRemindersApp() }
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Reminder Settings", systemImage: "gearshape") {
                            showsRemindersSettings = true
                        }
                    }
                }
            }
            .navigationTitle(Text("Timeline"))
            .sheet(isPresented: $showsCalendarSettings) {
                NavigationStack {
                    CalendarSettingsView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { showsCalendarSettings = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showsRemindersSettings) {
                NavigationStack {
                    RemindersSettingsView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { showsRemindersSettings = false }
                            }
                        }
                }
            }
            .sheet(item: $composing) { kind in
                TimelineItemComposer(kind: kind) { title, date in
                    Task {
                        switch kind {
                        case .pins: await model.addTimelinePin(title: title, date: date)
                        case .reminders: await model.addReminder(title: title, date: date)
                        }
                    }
                }
            }
            .task {
                await model.loadTimeline()
                await model.loadReminders()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .pins:
            TimelinePinsView(model: model)
        case .reminders:
            TimelineRemindersView(model: model)
        }
    }
}

struct TimelineItemComposer: View {
    var kind: TimelineListKind
    var add: (String, Date) -> Void
    @State private var title = ""
    @State private var date = Date()
    @Environment(\.dismiss) private var dismiss

    private var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    DatePicker(kind == .pins ? "Date" : "Time", selection: $date)
                } footer: {
                    switch kind {
                    case .pins:
                        Text("A pin waits on the watch's timeline until its moment, and stays there afterwards.")
                    case .reminders:
                        Text("A reminder buzzes on the watch when its time comes, rather than waiting on the timeline. The watch keeps the ones near today and forgets the rest.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text(kind.newTitle))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm) {
                        let value = title
                        let when = date
                        dismiss()
                        add(value, when)
                    }
                    .disabled(!isComplete)
                }
            }
        }
    }
}

#Preview("New pin") {
    TimelineItemComposer(kind: .pins) { _, _ in }
}

#Preview("New reminder") {
    TimelineItemComposer(kind: .reminders) { _, _ in }
}
