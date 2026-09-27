import Foundation
import Testing
import PebbleProtocol

@Suite struct WatchWrittenItemTests {
    /// What a watch sent after someone dictated a reminder to it, taken off the
    /// wire on 2026-09-02: a `WRITE` of the pin its Reminders app had just made.
    static let offeredPin: [UInt8] = [
        0x08, 0x0C, 0x00, 0x01, 0x2D, 0xD6, 0x97, 0x6A, 0x10,
        0xD0, 0x14, 0x7D, 0x20, 0xAB, 0xEB, 0x4E, 0x88,
        0xB1, 0xAC, 0xF4, 0x41, 0x56, 0x13, 0x47, 0x7F,
        0x9D, 0x00,
        // The item: its id, then the Reminders app's own UUID as its parent.
        0xD0, 0x14, 0x7D, 0x20, 0xAB, 0xEB, 0x4E, 0x88,
        0xB1, 0xAC, 0xF4, 0x41, 0x56, 0x13, 0x47, 0x7F,
        0x42, 0xA0, 0x72, 0x17, 0x54, 0x91, 0x42, 0x67,
        0x90, 0x4A, 0xD0, 0x2A, 0x15, 0x67, 0x52, 0xB6,
        0x80, 0xD7, 0x97, 0x6A,
        0x00, 0x00,
        0x02,
        0x08,
        0x00,
        0x01,
        0x6F, 0x00,
        0x03,
        0x03,
        // Icon, title, background colour.
        0x04, 0x04, 0x00, 0x03, 0x00, 0x00, 0x80,
        0x01, 0x38, 0x00,
        0xE8, 0xB5, 0xB7, 0xE3, 0x81, 0x93, 0xE3, 0x81, 0x97, 0xE3, 0x81, 0xA6, 0x20,
        0xE3, 0x80, 0x81, 0x20, 0x35, 0x20, 0xE6, 0x99, 0x82, 0x20, 0xE3, 0x81, 0xAB, 0x20,
        0xE8, 0xB5, 0xB7, 0x20, 0xE3, 0x81, 0x93, 0xE3, 0x81, 0x97, 0x20, 0xE3, 0x81, 0xA6, 0x20,
        0xE3, 0x81, 0x8F, 0x20, 0xE3, 0x81, 0xA0, 0x20, 0xE3, 0x81, 0x95, 0xE3, 0x81, 0x84,
        0x1C, 0x01, 0x00, 0xF8,
        // Completed, Postpone, Remove.
        0x00, 0x10, 0x01, 0x01, 0x09, 0x00, 0x43, 0x6F, 0x6D, 0x70, 0x6C, 0x65, 0x74, 0x65, 0x64,
        0x01, 0x11, 0x01, 0x01, 0x08, 0x00, 0x50, 0x6F, 0x73, 0x74, 0x70, 0x6F, 0x6E, 0x65,
        0x02, 0x12, 0x01, 0x01, 0x06, 0x00, 0x52, 0x65, 0x6D, 0x6F, 0x76, 0x65,
    ]

    private static func offeredWrite() throws -> BlobDB2Write {
        let message = try BlobDB2Codec.decode(PebbleProtocolFrame(
            endpoint: BlobDB2Codec.endpoint,
            payload: offeredPin
        ))
        guard case .write(let write) = message else {
            throw TimelinePinError.malformedItem
        }
        return write
    }

    @Test func aReminderDictatedToTheWatchArrivesWithItsWordsAndItsTime() throws {
        let write = try Self.offeredWrite()
        #expect(write.databaseID == TimelinePinCodec.databaseID)

        let item = try TimelinePin(decoding: write.value)

        #expect(item.id.uuidString == "D0147D20-ABEB-4E88-B1AC-F4415613477F")
        #expect(item.parentApplicationID.uuidString == "42A07217-5491-4267-904A-D02A156752B6")
        #expect(item.timestamp == Date(timeIntervalSince1970: 0x6A97_D780))
        #expect(item.kind == .pin)
        #expect(item.durationMinutes == 0)
        // What stops the app from writing this one back over the watch's own
        // copy, which has three actions and an icon this app does not model.
        #expect(item.isFromWatch)
        #expect(item.isAllDay == false)
        // The spaces are the watch's: this capture predates the fix that stopped
        // the app cutting a Japanese transcript at every recognized word.
        #expect(item.title == "起こして 、 5 時 に 起 こし て く だ さい")
        #expect(item.subtitle == nil)
        #expect(item.body == nil)
    }

    @Test func anItemWithNothingToReadIsRefusedRatherThanShownEmpty() throws {
        var headerOnly = Array(try Self.offeredWrite().value.prefix(46))
        headerOnly[44] = 0
        #expect(throws: TimelinePinError.malformedItem) {
            try TimelinePin(decoding: headerOnly)
        }
    }

    @Test func anItemCutShortIsRefusedRatherThanGuessedAt() throws {
        let value = try Self.offeredWrite().value
        #expect(throws: TimelinePinError.malformedItem) {
            try TimelinePin(decoding: Array(value.prefix(40)))
        }
        // The header promises three attributes and the bytes hold one.
        #expect(throws: TimelinePinError.malformedItem) {
            try TimelinePin(decoding: Array(value.prefix(56)))
        }
    }

    @Test func whatTheAppWritesAndWhatItReadsAreTheSameItem() throws {
        let pin = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            durationMinutes: 30,
            title: "牛乳を買う",
            subtitle: "スーパー",
            body: "特売の日",
            isAllDay: true,
            kind: .reminder
        )

        #expect(try TimelinePin(decoding: pin.encoded()) == pin)
    }
}
