import PebbleProtocol
import CryptoKit
import EventKit
import Foundation

/// A reminder in the phone's own Reminders app, beside the reminder it stands
/// for here.
///
/// The identifier travels with it because it is how the Reminders app is
/// addressed, and what has to be written down for an edit here to reach the
/// same reminder there rather than making a second one.
struct RemindersAppItem: Equatable, Sendable {
    var identifier: String
    var reminder: PebbleTimelinePin
}

/// As much of the phone's Reminders app as the watch has a place for.
///
/// A protocol so that a test can answer for the Reminders app, which cannot be
/// written to on a machine nobody has said yes on.
@MainActor
protocol RemindersAppStore {
    func reminders() async throws -> [RemindersAppItem]
    func add(_ reminder: PebbleTimelinePin) async throws -> String
    func update(_ reminder: PebbleTimelinePin, identifier: String) async throws
    func remove(identifier: String) async throws
}

@MainActor
final class RemindersBridge: RemindersAppStore {
    private let store = EKEventStore()

    /// Reminders are read as far ahead as calendar events are, and no further:
    /// the watch keeps a window around the present and refuses what is outside
    /// it, so a reminder for next year is one to read again nearer the time.
    private static var window: TimeInterval { 30 * 24 * 60 * 60 }

    func reminders() async throws -> [RemindersAppItem] {
        guard try await store.requestFullAccessToReminders() else {
            throw RemindersBridgeError.accessDenied
        }
        let start = Date()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: start,
            ending: start.addingTimeInterval(Self.window),
            calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).compactMap(Self.item(for:)))
            }
        }
    }

    func add(_ reminder: PebbleTimelinePin) async throws -> String {
        guard try await store.requestFullAccessToReminders() else {
            throw RemindersBridgeError.accessDenied
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw RemindersBridgeError.noList
        }
        let item = EKReminder(eventStore: store)
        item.calendar = list
        apply(reminder, to: item)
        try store.save(item, commit: true)
        return item.calendarItemIdentifier
    }

    func update(_ reminder: PebbleTimelinePin, identifier: String) async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw RemindersBridgeError.accessDenied
        }
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw RemindersBridgeError.gone
        }
        apply(reminder, to: item)
        try store.save(item, commit: true)
    }

    func remove(identifier: String) async throws {
        guard try await store.requestFullAccessToReminders() else {
            throw RemindersBridgeError.accessDenied
        }
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return
        }
        try store.remove(item, commit: true)
    }

    private func apply(_ reminder: PebbleTimelinePin, to item: EKReminder) {
        item.title = reminder.title
        item.notes = reminder.body
        item.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: reminder.timestamp
        )
        // No alarm is set: the watch is what buzzes for this reminder, and an
        // alarm here would have the phone buzz for it as well.
    }

    /// Read off the main actor, inside EventKit's own callback, so nothing of
    /// this class is touched: a reminder is turned into the value that leaves.
    private nonisolated static func item(for reminder: EKReminder) -> RemindersAppItem? {
        guard let components = reminder.dueDateComponents,
              let due = Calendar.current.date(from: components) else { return nil }
        let identifier = reminder.calendarItemIdentifier
        return RemindersAppItem(
            identifier: identifier,
            reminder: PebbleTimelinePin(
                id: stableID(identifier),
                parentApplicationID: applicationID,
                timestamp: due,
                title: reminder.title ?? "Reminder",
                subtitle: reminder.calendar.title,
                body: reminder.notes,
                kind: .reminder
            )
        )
    }

    /// The same reminder read twice is the same reminder: BlobDB is keyed by
    /// this, so a name derived from the Reminders app's own is what keeps a
    /// second reading from becoming a second reminder on the watch.
    private nonisolated static func stableID(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// What the watch is told made these reminders.
    nonisolated static var applicationID: UUID {
        UUID(uuidString: "4D4F4249-4C45-5245-4D49-4E4445520001")!
    }
}

enum RemindersBridgeError: Error, Equatable, Sendable {
    case accessDenied
    /// Nowhere to put a reminder: the Reminders app has no list to add to.
    case noList
    /// The reminder this app copied there is not there any more.
    case gone
}

/// What the reminders here should be, once the Reminders app has had its say.
///
/// Kept apart from the writing so it can be read as the rule it is: what the
/// Reminders app has replaces what was read from it last time, what the watch
/// made stays, and what was copied over and has since been finished there is
/// finished here too.
enum RemindersAppSync {
    struct Outcome: Equatable {
        var reminders: [PebbleTimelinePin]
        /// Reminders the watch made whose copy in the Reminders app has been
        /// completed or deleted, which is the only word this app gets that the
        /// reader is done with them.
        var finished: [PebbleTimelinePin]
    }

    static func merged(
        kept: [PebbleTimelinePin],
        fromApp: [RemindersAppItem],
        mirrored: [UUID: String],
        now: Date
    ) -> Outcome {
        let present = Set(fromApp.map(\.identifier))
        let copies = Set(mirrored.values)
        // A reminder this app copied into the Reminders app is read back from
        // it as well, and taking both would put the same reminder on the watch
        // twice under two names.
        let arrived = fromApp.filter { !copies.contains($0.identifier) }.map(\.reminder)
        var mine = kept.filter { $0.parentApplicationID != RemindersBridge.applicationID }
        let finished = mine.filter { reminder in
            // Only what is still to come: a copy whose day has passed is out of
            // the window that was read, and absence there says nothing about it.
            guard reminder.timestamp > now, let identifier = mirrored[reminder.id] else { return false }
            return !present.contains(identifier)
        }
        let gone = Set(finished.map(\.id))
        mine.removeAll { gone.contains($0.id) }
        return Outcome(
            reminders: (mine + arrived).sorted { $0.timestamp < $1.timestamp },
            finished: finished
        )
    }
}
