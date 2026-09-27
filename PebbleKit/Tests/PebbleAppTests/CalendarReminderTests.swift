import EventKit
import Foundation
import PebbleProtocol
import PebbleTransport
import Testing
@testable import PebbleApp

/// Calendar event alerts becoming reminders in the watch's Reminder database
/// (#94, slice 2).
@MainActor
@Suite
struct CalendarReminderTests {
    private func eventPin(startingIn hours: Double = 2) -> TimelinePin {
        TimelinePin(
            parentApplicationID: CalendarBridge.calendarApplicationID,
            timestamp: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + hours * 3600).rounded()),
            title: "打ち合わせ",
            subtitle: "仕事",
            body: "会議室A"
        )
    }

    /// `reminders.c` reads the parent out of the pin database to work out a
    /// snooze, so the parent must be the pin — not the calendar app.
    @Test func aReminderBelongsToItsPin() {
        let pin = eventPin()
        let fire = pin.timestamp.addingTimeInterval(-15 * 60)

        let reminders = CalendarBridge.eventReminders(for: pin, occurrenceKey: "key", fireDates: [fire])

        #expect(reminders.map(\.parentApplicationID) == [pin.id])
        #expect(reminders.map(\.timestamp) == [fire])
        #expect(reminders.map(\.title) == ["打ち合わせ"])
        #expect(reminders.map(\.body) == ["会議室A"])
        #expect(reminders.map(\.kind) == [.reminder])
    }

    /// BlobDB is keyed by the identifier: the same alert read twice must be the
    /// same reminder, and two alerts of one event must not collide.
    @Test func theSameAlertReadTwiceIsTheSameReminder() {
        let pin = eventPin()
        let quarter = pin.timestamp.addingTimeInterval(-15 * 60)
        let hour = pin.timestamp.addingTimeInterval(-60 * 60)

        let first = CalendarBridge.eventReminders(for: pin, occurrenceKey: "key", fireDates: [quarter, hour])
        let second = CalendarBridge.eventReminders(for: pin, occurrenceKey: "key", fireDates: [quarter, hour])

        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == 2)
    }

    /// An event carrying the same alert twice should buzz once, not twice.
    @Test func aDuplicatedAlertBuzzesOnce() {
        let pin = eventPin()
        let fire = pin.timestamp.addingTimeInterval(-10 * 60)

        let reminders = CalendarBridge.eventReminders(for: pin, occurrenceKey: "key", fireDates: [fire, fire])

        #expect(reminders.count == 1)
    }

    /// EventKit keeps an alarm as a date of its own or an offset from the
    /// start; both must land on the moment the phone would buzz at.
    @Test func bothAlarmShapesFindTheirMoment() {
        let start = Date(timeIntervalSince1970: 1_760_000_000)
        let relative = EKAlarm(relativeOffset: -30 * 60)
        let absolute = EKAlarm(absoluteDate: Date(timeIntervalSince1970: 1_759_990_000))

        #expect(CalendarBridge.fireDate(of: relative, eventStart: start) == start.addingTimeInterval(-30 * 60))
        #expect(CalendarBridge.fireDate(of: absolute, eventStart: start) == Date(timeIntervalSince1970: 1_759_990_000))
    }

    @Test func anAllDayEventInTokyoIsAnchoredAtUTCMidnightOfItsDate() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        // 2026-08-13 00:00 in Tokyo is 2026-08-12 15:00 UTC.
        let localMidnight = Date(timeIntervalSince1970: 1_786_546_800)

        let anchored = CalendarBridge.anchoredToUTCMidnight(localMidnight, in: tokyo)

        // 2026-08-13 00:00 UTC.
        #expect(anchored == Date(timeIntervalSince1970: 1_786_579_200))
    }

    @Test func anAllDayEventInNewYorkIsAnchoredAtUTCMidnightOfItsDate() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        // 2026-08-13 00:00 in New York (EDT) is 2026-08-13 04:00 UTC.
        let localMidnight = Date(timeIntervalSince1970: 1_786_593_600)

        let anchored = CalendarBridge.anchoredToUTCMidnight(localMidnight, in: newYork)

        #expect(anchored == Date(timeIntervalSince1970: 1_786_579_200))
    }

    @Test func anAllDayEventsReminderIsNotAllDay() {
        var pin = eventPin()
        pin.isAllDay = true

        let reminders = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [pin.timestamp.addingTimeInterval(-15 * 60)]
        )

        #expect(reminders.map(\.isAllDay) == [false])
    }

    @Test func anAlertsIdentifierIsTheUnstampedDigestItWasMintedWith() {
        let pin = eventPin()

        let reminder = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [Date(timeIntervalSince1970: 1_760_000_000)]
        )[0]

        // The first sixteen bytes of SHA-256("reminder|key|1760000000.0").
        #expect(reminder.id == UUID(uuidString: "FFD41010-B1A3-5163-86EF-4E39ACE0D998"))
    }

    /// `notification_window.c` hides the popup's action button unless the item
    /// carries an action of its own, and the firmware's Snooze only appears
    /// inside that menu — a reminder with no actions can be neither dismissed
    /// nor snoozed. So every reminder carries a Dismiss, and a pin carries
    /// nothing new.
    @Test func aReminderCarriesADismissSoTheWatchOffersItsMenu() throws {
        let pin = eventPin()
        let reminder = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [pin.timestamp.addingTimeInterval(-15 * 60)]
        )[0]

        let bytes = try reminder.encoded()
        // Byte 45 is the action count, after the attribute count at 44.
        #expect(bytes[45] == 1)
        // The action trails the attributes: `SerializedActionHeader` (id, type
        // Dismiss = 0x04, one attribute), then the label as attribute 0x01.
        let action = Array(bytes.suffix(13))
        #expect(Array(action.prefix(3)) == [0x01, 0x04, 0x01])
        #expect(Array(action[3..<6]) == [0x01, 7, 0])
        #expect(String(decoding: action.suffix(7), as: UTF8.self) == "Dismiss")

        #expect(try pin.encoded()[45] == 0)
    }

    // MARK: The watch

    private func connectedModel(in directory: URL, client: MockWatchClient) async throws -> AppModel {
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        return model
    }

    @Test func aCalendarReminderReachesTheWatchAndLeavesWithItsAlert() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client)
        let connection = try #require(model.activeConnections.first)
        let pin = eventPin()
        let reminder = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [pin.timestamp.addingTimeInterval(-15 * 60)]
        )[0]

        try await model.calendarReminderStore.save([reminder])
        await model.synchronizeCalendarReminders(on: connection)

        #expect(client.timelineReminders.map(\.id) == [reminder.id])
        #expect(client.timelineReminders.map(\.parentApplicationID) == [pin.id])

        // The alert vanishing from the calendar is its reminder leaving the watch.
        try await model.calendarReminderStore.save([])
        await model.synchronizeCalendarReminders(on: connection)

        #expect(client.timelineReminders.isEmpty)
    }

    /// One in the past has already buzzed or been missed, and the watch refuses
    /// anything older than fifteen minutes outright.
    @Test func anAlertWhoseMomentHasPassedIsNotSent() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client)
        let connection = try #require(model.activeConnections.first)
        let pin = eventPin(startingIn: -1)
        let reminder = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [pin.timestamp.addingTimeInterval(-15 * 60)]
        )[0]

        try await model.calendarReminderStore.save([reminder])
        await model.synchronizeCalendarReminders(on: connection)

        #expect(client.timelineReminders.isEmpty)
    }

    /// A retitled event keeps its reminder's identifier and changes its bytes,
    /// which is what the digest is there to notice.
    @Test func aRetitledEventsReminderIsWrittenAgainAndAnUntouchedOneIsNot() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try await connectedModel(in: directory, client: client)
        let connection = try #require(model.activeConnections.first)
        let pin = eventPin()
        var reminder = CalendarBridge.eventReminders(
            for: pin,
            occurrenceKey: "key",
            fireDates: [pin.timestamp.addingTimeInterval(-15 * 60)]
        )[0]
        try await model.calendarReminderStore.save([reminder])
        await model.synchronizeCalendarReminders(on: connection)
        let writesBefore = client.timelineReminderWrites.count

        // Nothing changed: nothing is sent.
        await model.synchronizeCalendarReminders(on: connection)
        #expect(client.timelineReminderWrites.count == writesBefore)

        reminder.title = "打ち合わせ（変更）"
        try await model.calendarReminderStore.save([reminder])
        await model.synchronizeCalendarReminders(on: connection)

        #expect(client.timelineReminders.map(\.title) == ["打ち合わせ（変更）"])
    }
}
