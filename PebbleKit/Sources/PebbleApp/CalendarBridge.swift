import PebbleProtocol
import CryptoKit
import EventKit
import Foundation

/// One calendar on the phone, as the settings screen lists it.
struct PhoneCalendar: Identifiable, Equatable, Sendable {
    /// `EKCalendar.calendarIdentifier`, which EventKit warns can change — a
    /// full sync may hand every calendar a new one. `CalendarPreference`
    /// carries the title and source along so a choice survives that.
    var id: String
    var title: String
    var sourceTitle: String
}

/// The reader's choice for one calendar, stored so it survives both launches
/// and EventKit reissuing identifiers.
struct CalendarPreference: Codable, Equatable, Sendable {
    var identifier: String
    var title: String
    var sourceTitle: String
    var isEnabled: Bool

    /// Whether this preference speaks for that calendar: by identifier where
    /// it still matches, and by name and owner where EventKit has reissued it.
    func matches(_ calendar: PhoneCalendar) -> Bool {
        identifier == calendar.id
            || (title == calendar.title && sourceTitle == calendar.sourceTitle)
    }

    /// Which calendars of the given list are enabled, defaulting to enabled: a
    /// calendar never seen before should appear on the watch, not vanish until
    /// somebody finds the switch.
    static func enabledIdentifiers(
        of calendars: [PhoneCalendar],
        given preferences: [CalendarPreference]
    ) -> Set<String> {
        Set(calendars.filter { calendar in
            preferences.first { $0.matches(calendar) }?.isEnabled ?? true
        }.map(\.id))
    }

    /// The stored preferences brought up to date with what EventKit lists now:
    /// identifiers reissued since last time are rewritten on the name-and-owner
    /// match, and calendars that no longer exist keep their row — a calendar
    /// that comes back (an account signed out and in) should come back with
    /// its choice.
    static func migrated(
        _ preferences: [CalendarPreference],
        against calendars: [PhoneCalendar]
    ) -> [CalendarPreference] {
        preferences.map { preference in
            guard let calendar = calendars.first(where: { preference.matches($0) }) else {
                return preference
            }
            var updated = preference
            updated.identifier = calendar.id
            updated.title = calendar.title
            updated.sourceTitle = calendar.sourceTitle
            return updated
        }
    }
}

@MainActor
final class CalendarBridge {
    private var store = EKEventStore()

    /// Asks without reading anything, for the setup flow: everywhere else the
    /// question comes with work to do the moment it is answered.
    func requestAccess() async throws {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
    }

    /// The calendars the phone has, for the settings screen.
    func calendars() async throws -> [PhoneCalendar] {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
        return store.calendars(for: .event).map {
            PhoneCalendar(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }
        .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func timelinePins(
        disabledCalendarIdentifiers: Set<String> = [],
        includeDeclined: Bool = false
    ) async throws -> [TimelinePin] {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: start) ?? start
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !disabledCalendarIdentifiers.contains($0.calendar.calendarIdentifier) }
            // A declined meeting is one the reader said they will not be at;
            // its pin would be a reminder of a decision already made. Kept
            // only when asked for.
            .filter { includeDeclined || !Self.isDeclined($0) }
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

    /// Whether the phone's own account declined this event. An event with no
    /// attendees has nobody to have declined it.
    static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    static var calendarApplicationID: UUID { UUID(uuidString: "4D4F4249-4C45-4341-4C45-4E4441520001")! }
}

enum CalendarBridgeError: Error { case accessDenied }
