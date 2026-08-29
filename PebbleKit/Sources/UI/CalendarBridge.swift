import API
import CryptoKit
import EventKit
import Foundation
import MemberwiseInit

@MainActor
final class CalendarBridge {
    private var store = EKEventStore()

    func timelinePins() async throws -> [PebbleTimelinePin] {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        var pins = events.map { event in
            PebbleTimelinePin(
                id: stableID(event.eventIdentifier ?? "\(event.title ?? "")|\(event.startDate.timeIntervalSince1970)"),
                parentApplicationID: Self.calendarApplicationID,
                timestamp: event.startDate,
                durationMinutes: UInt16(clamping: Int(event.endDate.timeIntervalSince(event.startDate) / 60)),
                title: event.title ?? "Calendar Event",
                subtitle: event.calendar.title,
                body: event.location,
                isAllDay: event.isAllDay
            )
        }
        if try await store.requestFullAccessToReminders() {
            let reminders = await reminders(from: start, through: end)
            pins += reminders.compactMap { reminder in
                guard let dueDateComponents = reminder.dueDateComponents,
                      let dueDate = Calendar.current.date(from: dueDateComponents) else { return nil }
                return PebbleTimelinePin(
                    id: stableID(reminder.identifier),
                    parentApplicationID: Self.calendarApplicationID,
                    timestamp: dueDate,
                    title: reminder.title,
                    subtitle: reminder.calendarTitle,
                    body: reminder.notes
                )
            }
        }
        return pins.sorted { $0.timestamp < $1.timestamp }
    }

    private func reminders(from start: Date, through end: Date) async -> [ReminderValue] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: start, ending: end, calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map {
                    ReminderValue(
                        identifier: $0.calendarItemIdentifier,
                        title: $0.title ?? "Reminder",
                        calendarTitle: $0.calendar.title,
                        dueDateComponents: $0.dueDateComponents,
                        notes: $0.notes
                    )
                })
            }
        }
    }

    @MemberwiseInit(.fileprivate)
    fileprivate struct ReminderValue: Sendable {
        var identifier: String
        var title: String
        var calendarTitle: String
        var dueDateComponents: DateComponents?
        var notes: String?
    }

    private func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static var calendarApplicationID: UUID { UUID(uuidString: "4D4F4249-4C45-4341-4C45-4E4441520001")! }
}

enum CalendarBridgeError: Error { case accessDenied }
