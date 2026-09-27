import Foundation
import Testing
@testable import PebbleProtocol

/// How a `WatchID` is written down.
///
/// It replaced a bare `String`, and two of the files on disk are keyed by it.
/// A dictionary whose key is neither a string nor an integer has no object
/// form, so `JSONEncoder` writes it as an array of alternating keys and values
/// — which would have left every reader's record of what their watches hold
/// unreadable by the version that wrote it, and silently: the array decodes
/// back into a dictionary quite happily, just not the one the old file holds.
@Suite
@MainActor
struct WatchIDTests {
    @Test func oneIdentifierIsWrittenAsABareString() throws {
        let encoded = try JSONEncoder().encode(WatchID("mock-flint"))
        #expect(String(decoding: encoded, as: UTF8.self) == "\"mock-flint\"")
        #expect(try JSONDecoder().decode(WatchID.self, from: encoded) == WatchID("mock-flint"))
    }

    @Test func aDictionaryKeyedByWatchStaysAJSONObject() throws {
        let applicationID = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
        let states: [WatchID: [UUID]] = [WatchID("mock-flint"): [applicationID]]

        let encoded = try JSONEncoder().encode(states)
        let object = try JSONSerialization.jsonObject(with: encoded)

        // An array here is the failure this conformance exists to prevent.
        let keyed = try #require(object as? [String: Any])
        #expect(Array(keyed.keys) == ["mock-flint"])
        #expect(try JSONDecoder().decode([WatchID: [UUID]].self, from: encoded) == states)
    }

    /// The file itself, not just the type: `application-sync.json` is what a
    /// reader's install carries, and it is written through `PersistentJSON`.
    @Test func theSynchronizationFileIsAnObjectKeyedByTheIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let applicationID = UUID()

        try await library.setSynchronizedApplicationIDs([applicationID], watchID: WatchID("mock-flint"))

        let written = try Data(contentsOf: directory.appending(path: "application-sync.json"))
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        #expect(try #require(object).keys.contains("mock-flint"))
        #expect(
            try await library.synchronizedApplicationIDs(watchID: WatchID("mock-flint")) == [applicationID]
        )
    }

    /// Which pin each watch holds and which reminder mirrors which are keyed the
    /// same way, and by the same argument.
    @Test func thePinsWrittenToEachWatchAreKeptUnderItsIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))
        let pinID = UUID()

        try await store.setWrittenPinIDs([pinID], watchID: WatchID("mock-flint"))

        let written = try Data(contentsOf: directory.appending(path: "timeline-written.json"))
        let object = try JSONSerialization.jsonObject(with: written) as? [String: Any]
        #expect(try #require(object).keys.contains("mock-flint"))
        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")) == [pinID])
        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-emery")).isEmpty)
    }

    /// Which reminder here is which one in the phone's Reminders app. A
    /// `[UUID: String]` encodes as one flat array of alternating strings, so
    /// the file is an array of pairs that say which is which.
    @Test func theMirroredRemindersAreWrittenAsNamedPairs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.reminders.json"))
        let reminderID = UUID()

        try await store.setMirroredIdentifiers([reminderID: "x-apple-reminder://A1"])

        let written = try Data(contentsOf: directory.appending(path: "timeline.reminders-mirrored.json"))
        let pairs = try #require(try JSONSerialization.jsonObject(with: written) as? [[String: String]])
        #expect(pairs == [["id": reminderID.uuidString, "externalIdentifier": "x-apple-reminder://A1"]])
        #expect(try await store.mirroredIdentifiers() == [reminderID: "x-apple-reminder://A1"])
    }

    /// What `Defaults` keeps a dictionary keyed by watch under, which has to be
    /// the identifier itself for the stored shape to be the one a
    /// `[String: …]` keyed by the raw value had.
    @Test func anIdentifierIsWrittenAndReadAsItsOwnText() {
        let watchID = WatchID("5F1E2D3C-4B5A-6978-8765-4321ABCDEF00")

        #expect(watchID.description == "5F1E2D3C-4B5A-6978-8765-4321ABCDEF00")
        #expect(WatchID(watchID.description) == watchID)
    }

    private func samplePin(title: String) -> TimelinePin {
        TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            title: title,
            subtitle: nil,
            body: nil
        )
    }

    /// Beside each identifier is a digest of the bytes the pin was written as,
    /// so a synchronization can send only the pins that changed. It has to be
    /// stable across launches, which `Hashable` is not: Swift seeds that hash
    /// per process.
    @Test func aPinsDigestFollowsTheBytesItIsWrittenAs() throws {
        var pin = samplePin(title: "Dentist")
        let first = pin.writtenDigest
        #expect(first.count == 64)
        #expect(pin.writtenDigest == first)

        pin.title = "Dentist, moved"
        #expect(pin.writtenDigest != first)

        // Not the pin's identity: a field the watch is never told about does not
        // move the digest, because the bytes it is written as do not change.
        var elsewhere = pin
        elsewhere.isFromWatch = !pin.isFromWatch
        #expect(elsewhere.writtenDigest == pin.writtenDigest)
    }

    /// A reminder's Dismiss is labelled in the reader's language, which the
    /// watch draws as given. The label is part of the bytes, so changing it
    /// changes the digest and the reminder is written again.
    @Test func aRemindersDismissCarriesTheTitleItIsGiven() throws {
        var reminder = samplePin(title: "歯医者")
        reminder.kind = .reminder
        reminder.dismissTitle = "閉じる"

        let bytes = try reminder.encoded()
        let label = TimelineItemHeader.textAttribute(id: 0x01, value: "閉じる", maximumByteCount: 64)
        // `SerializedActionHeader`: id 1, type 0x04 (dismiss), one attribute.
        #expect(Array(bytes.suffix(3 + label.count)) == [0x01, 0x04, 0x01] + label)
        #expect(bytes[45] == 1)

        var english = reminder
        english.dismissTitle = "Dismiss"
        #expect(english.writtenDigest != reminder.writtenDigest)
    }

    /// Without a title the action goes untitled, for the watch to label, rather
    /// than with an English word no reader chose.
    @Test func aRemindersDismissWithoutATitleCarriesNoAttribute() throws {
        var reminder = samplePin(title: "歯医者")
        reminder.kind = .reminder

        let bytes = try reminder.encoded()

        #expect(Array(bytes.suffix(3)) == [0x01, 0x04, 0x00])
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Dismiss"))
    }

    /// The label is the phone's language at the moment of writing, so it is
    /// not kept with the reminder.
    @Test func aDismissTitleIsNotStored() throws {
        var reminder = samplePin(title: "歯医者")
        reminder.kind = .reminder
        reminder.dismissTitle = "閉じる"

        let decoded = try JSONDecoder().decode(TimelinePin.self, from: JSONEncoder().encode(reminder))

        #expect(decoded.dismissTitle == nil)
        #expect(decoded.title == "歯医者")
    }

    @Test func aPinsDigestIsKeptUnderItsWatchsIdentifier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))
        let pin = samplePin(title: "Dentist")

        try await store.setWrittenPinDigests([pin.id: pin.writtenDigest], watchID: WatchID("mock-flint"))

        #expect(
            try await store.writtenPinDigests(watchID: WatchID("mock-flint"))
                == [pin.id: pin.writtenDigest]
        )
        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")) == [pin.id])
        #expect(try await store.writtenPinDigests(watchID: WatchID("mock-emery")).isEmpty)
    }

    /// The reminders are sent from a queue rather than derived from what the app
    /// holds, so they name their pins without a digest. Noting one more must not
    /// take the digests off the others, or the next synchronization would send
    /// every pin again.
    @Test func namingAPinDoesNotForgetTheDigestsBesideIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))
        let watchID = WatchID("mock-flint")
        let known = samplePin(title: "Dentist")
        let arriving = samplePin(title: "Dictated on the watch")

        try await store.setWrittenPinDigests([known.id: known.writtenDigest], watchID: watchID)
        var held = try await store.writtenPinIDs(watchID: watchID)
        held.insert(arriving.id)
        try await store.setWrittenPinIDs(held, watchID: watchID)

        let digests = try await store.writtenPinDigests(watchID: watchID)
        #expect(digests[known.id] == known.writtenDigest)
        // Named but never written by the app, so no digest can match it.
        #expect(digests[arriving.id] == "")
        #expect(digests[arriving.id] != arriving.writtenDigest)
    }
}
