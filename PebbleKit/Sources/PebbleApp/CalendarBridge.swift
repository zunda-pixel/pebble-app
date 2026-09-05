import PebbleProtocol
import CryptoKit
import EventKit
import Foundation

@MainActor
final class CalendarBridge {
    private var store = EKEventStore()

    /// Asks without reading anything, for the setup flow: everywhere else the
    /// question comes with work to do the moment it is answered.
    func requestAccess() async throws {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
    }

    func timelinePins() async throws -> [TimelinePin] {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
        // Reminders are read too, but as reminders: `RemindersBridge` puts them
        // in the database the watch buzzes from rather than on the timeline,
        // where they could only be looked at.
        let pins = events.map { event in
            TimelinePin(
                id: stableID(Self.occurrenceKey(
                    identity: event.eventIdentifier ?? event.title ?? "Calendar Event",
                    occurrence: event.occurrenceDate ?? event.startDate
                )),
                parentApplicationID: Self.calendarApplicationID,
                timestamp: event.startDate,
                durationMinutes: UInt16(clamping: Int(event.endDate.timeIntervalSince(event.startDate) / 60)),
                title: event.title ?? "Calendar Event",
                subtitle: event.calendar.title,
                body: event.location,
                isAllDay: event.isAllDay
            )
        }
        return pins.sorted { $0.timestamp < $1.timestamp }
    }

    /// What tells one occurrence of an event from another.
    ///
    /// `EKEvent.eventIdentifier` is one per event, not one per occurrence:
    /// every week of a weekly meeting carries the same one, which is why
    /// `occurrenceDate` exists at all. Keying pins on the identifier alone gave
    /// a whole recurring series a single pin — the app held several under that
    /// one id, the watch overwrote them into one BlobDB record so only one week
    /// ever showed, and every synchronization sent all of them again because
    /// only one could match the digest kept under the key.
    ///
    /// `occurrenceDate` rather than `startDate`: it stays put when an
    /// occurrence is detached and moved, so editing one week does not turn it
    /// into a new pin and orphan the old one on the watch.
    static func occurrenceKey(identity: String, occurrence: Date) -> String {
        "\(identity)|\(occurrence.timeIntervalSince1970)"
    }

    private func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static var calendarApplicationID: UUID { UUID(uuidString: "4D4F4249-4C45-4341-4C45-4E4441520001")! }
}

enum CalendarBridgeError: Error { case accessDenied }
