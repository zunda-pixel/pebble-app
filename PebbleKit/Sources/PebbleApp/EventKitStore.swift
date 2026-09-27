import PebbleProtocol
import EventKit
import Foundation

/// The app's one `EKEventStore`, and everything done with it.
///
/// One, because EventKit's objects belong to the store that fetched them and
/// Apple asks for a single long-lived one; the calendar and the Reminders app
/// each made their own. An actor, because the store is not `Sendable` and its
/// reads are synchronous: reading a month of every calendar ran on the main
/// actor, after every change EventKit reported. What leaves is values —
/// pins, calendars, identifiers — and nothing of EventKit's own.
actor EventKitStore {
    static let shared = EventKitStore()

    private let store = EKEventStore()

    func requestFullAccessToEvents() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func requestFullAccessToReminders() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    // MARK: Calendars

    func calendars() -> [PhoneCalendar] {
        store.calendars(for: .event).map {
            PhoneCalendar(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }
    }

    func timelineRead(
        from start: Date,
        to end: Date,
        now: Date,
        disabledCalendarIdentifiers: Set<String>,
        includeDeclined: Bool,
        remindersEnabled: Bool
    ) -> CalendarTimelineRead {
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        return CalendarBridge.timelineRead(
            of: events,
            now: now,
            disabledCalendarIdentifiers: disabledCalendarIdentifiers,
            includeDeclined: includeDeclined,
            remindersEnabled: remindersEnabled
        )
    }

    // MARK: The Reminders app

    func incompleteReminders(
        from start: Date,
        to end: Date,
        allDayAt time: DateComponents
    ) async -> [RemindersAppItem] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: start,
            ending: end,
            calendars: nil
        )
        return await withCheckedContinuation { continuation in
            // Read inside EventKit's own callback, so nothing of EventKit's
            // leaves it: a reminder is turned into the value that does.
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap {
                    RemindersBridge.item(for: $0, allDayAt: time)
                })
            }
        }
    }

    func addReminder(_ reminder: TimelinePin) throws -> String {
        guard let list = store.defaultCalendarForNewReminders() else {
            throw RemindersBridgeError.noList
        }
        let item = EKReminder(eventStore: store)
        item.calendar = list
        RemindersBridge.apply(reminder, to: item)
        try store.save(item, commit: true)
        return item.calendarItemIdentifier
    }

    func updateReminder(_ reminder: TimelinePin, identifier: String) throws {
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw RemindersBridgeError.gone
        }
        RemindersBridge.apply(reminder, to: item)
        try store.save(item, commit: true)
    }

    func removeReminder(identifier: String) throws {
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return
        }
        try store.remove(item, commit: true)
    }
}
