import PebbleProtocol
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

/// What one read of the phone's calendars produces: the events as pins, and
/// their alerts as reminders. Two lists of the same type — named so a caller
/// cannot put the buzzing list on the timeline by swapping a tuple's halves.
struct CalendarTimelineRead {
    var pins: [TimelinePin]
    var reminders: [TimelinePin]
}

@MainActor
final class CalendarBridge {
    private var store = EKEventStore()

    /// The only place the system's question is asked. The reads below check
    /// the standing answer instead: they are reached from EventKit's own change
    /// notices too, and nothing the reader did not start may raise the sheet.
    func requestAccess() async throws {
        guard try await store.requestFullAccessToEvents() else { throw CalendarBridgeError.accessDenied }
    }

    private func requireAccess() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarBridgeError.accessDenied
        }
    }

    /// The calendars the phone has, for the settings screen.
    func calendars() async throws -> [PhoneCalendar] {
        try requireAccess()
        return store.calendars(for: .event).map {
            PhoneCalendar(id: $0.calendarIdentifier, title: $0.title, sourceTitle: $0.source.title)
        }
        .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func timelinePins(
        disabledCalendarIdentifiers: Set<String> = [],
        includeDeclined: Bool = false,
        remindersEnabled: Bool = false
    ) async throws -> CalendarTimelineRead {
        try requireAccess()
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !disabledCalendarIdentifiers.contains($0.calendar.calendarIdentifier) }
            // A declined meeting is one the reader said they will not be at;
            // its pin would be a reminder of a decision already made. Kept
            // only when asked for.
            .filter { includeDeclined || !Self.isDeclined($0) }
        // Reminders are read too, but as reminders: `RemindersBridge` puts them
        // in the database the watch buzzes from rather than on the timeline,
        // where they could only be looked at.
        var pins: [TimelinePin] = []
        var reminders: [TimelinePin] = []
        for event in events {
            let key = Self.occurrenceKey(
                identity: event.eventIdentifier ?? event.title ?? "Calendar Event",
                occurrence: event.occurrenceDate ?? event.startDate
            )
            let pin = TimelinePin(
                id: UUID(stableDigestOf: key),
                parentApplicationID: Self.calendarApplicationID,
                timestamp: event.isAllDay ? Self.anchoredToUTCMidnight(event.startDate) : event.startDate,
                durationMinutes: event.isAllDay
                    ? 0
                    : UInt16(clamping: Int(event.endDate.timeIntervalSince(event.startDate) / 60)),
                title: event.title ?? String(localized: "Calendar Event", bundle: .module),
                subtitle: event.calendar.title,
                body: event.location,
                isAllDay: event.isAllDay
            )
            pins.append(pin)
            guard remindersEnabled else { continue }
            reminders += Self.eventReminders(
                for: pin,
                occurrenceKey: key,
                fireDates: (event.alarms ?? [])
                    .map { Self.fireDate(of: $0, eventStart: event.startDate) }
                    .filter { $0 > now }
            )
        }
        return CalendarTimelineRead(
            pins: pins.sorted { $0.timestamp < $1.timestamp },
            reminders: reminders.sorted { $0.timestamp < $1.timestamp }
        )
    }

    /// When an alarm goes off. EventKit keeps one of two shapes: a date of its
    /// own, or an offset from the event's start — negative for before, the
    /// usual case.
    static func fireDate(of alarm: EKAlarm, eventStart: Date) -> Date {
        alarm.absoluteDate ?? eventStart.addingTimeInterval(alarm.relativeOffset)
    }

    /// The event's alarms as reminders for the watch's Reminder database, which
    /// buzzes for each at its moment — the phone's own advance notice, kept
    /// when the phone is out of reach.
    ///
    /// The parent is the *pin*, not the calendar app: `reminders.c` looks the
    /// parent up in the pin database to work out how long a snooze should be.
    /// The identifier is derived from the occurrence and the alarm's moment, so
    /// reading the same alarm twice is the same reminder, and moving an alarm
    /// is one reminder leaving and another arriving.
    static func eventReminders(
        for pin: TimelinePin,
        occurrenceKey: String,
        fireDates: [Date]
    ) -> [TimelinePin] {
        // An event can carry the same alert twice; the watch would buzz twice.
        var seen: Set<Date> = []
        return fireDates.sorted(by: <).compactMap { fire in
            guard seen.insert(fire).inserted else { return nil }
            return TimelinePin(
                id: UUID(stableDigestOf: "reminder|\(occurrenceKey)|\(fire.timeIntervalSince1970)"),
                parentApplicationID: pin.id,
                timestamp: fire,
                title: pin.title,
                subtitle: nil,
                body: pin.body,
                // The alarm's moment is absolute. Flagged all-day, the watch
                // would take its own offset off it as it does off the pin's
                // (`timeline_item_get_tz_timestamp`), and buzz hours early or late.
                isAllDay: false,
                kind: .reminder
            )
        }
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

    /// An all-day event's start as UTC midnight of its local date.
    ///
    /// The watch reads an all-day timestamp as local wall-clock time and takes
    /// its own offset off it (`timeline_item_get_tz_timestamp` →
    /// `time_local_to_utc`, `services/timeline/item.c`), and files an item as
    /// all-day only when what is left is that day's midnight (`timeline.c:109`,
    /// `node->all_day && node->timestamp == midnight`). The local midnight
    /// EventKit hands over has the offset taken off twice — nine hours early in
    /// Japan. The official app anchors the same way (`anchorAllDayToUtc`,
    /// `CalendarEvent.kt`).
    nonisolated static func anchoredToUTCMidnight(_ date: Date, in timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        let wallClock = local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return utc.date(from: wallClock) ?? date
    }

    /// Whether the phone's own account declined this event. An event with no
    /// attendees has nobody to have declined it.
    static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    nonisolated static let calendarApplicationID = UUID(uuid: (
        0x4D, 0x4F, 0x42, 0x49, 0x4C, 0x45, 0x43, 0x41, 0x4C, 0x45, 0x4E, 0x44, 0x41, 0x52, 0x00, 0x01
    ))
}

enum CalendarBridgeError: Error { case accessDenied }
