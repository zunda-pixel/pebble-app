import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// Pins a watch app's JavaScript pushes: the timeline web API's JSON read into
/// this app's pins, owned by the application whose script said so.
@Suite
@MainActor
struct CompanionTimelinePinTests {
    @Test func theWebPinsWordsAndTimesAreRead() throws {
        let pin = try CompanionTimelinePin.parse("""
        {
          "id": "bus-42",
          "time": "2026-09-22T08:15:00.000Z",
          "duration": 15,
          "layout": {
            "type": "genericPin",
            "title": "Bus 42",
            "subtitle": "Platform 2",
            "body": "Towards the harbour"
          }
        }
        """)

        let expected = try Date(
            "2026-09-22T08:15:00Z",
            strategy: .iso8601
        )
        #expect(pin.backingID == "bus-42")
        #expect(pin.time == expected)
        #expect(pin.durationMinutes == 15)
        #expect(pin.title == "Bus 42")
        #expect(pin.subtitle == "Platform 2")
        #expect(pin.body == "Towards the harbour")
    }

    /// The web API lets a layout carry only the short spellings, and "" is the
    /// store-JSON way of saying nothing.
    @Test func shortSpellingsStandInAndEmptyStringsDoNot() throws {
        let pin = try CompanionTimelinePin.parse("""
        {
          "id": "x",
          "time": "2026-09-22T08:15:00Z",
          "layout": {"type": "genericPin", "title": "", "shortTitle": "Bus", "shortSubtitle": "2"}
        }
        """)

        #expect(pin.title == "Bus")
        #expect(pin.subtitle == "2")
        #expect(pin.durationMinutes == 0)
    }

    @Test func whatCannotBeAPinIsRefusedByName() {
        #expect(throws: CompanionTimelinePin.ParseError.unreadable) {
            try CompanionTimelinePin.parse("not json")
        }
        #expect(throws: CompanionTimelinePin.ParseError.missingEssentials) {
            try CompanionTimelinePin.parse(#"{"time": "2026-09-22T08:15:00Z", "layout": {"type": "genericPin", "title": "t"}}"#)
        }
        #expect(throws: CompanionTimelinePin.ParseError.missingEssentials) {
            try CompanionTimelinePin.parse(#"{"id": "x", "time": "yesterday-ish", "layout": {"type": "genericPin", "title": "t"}}"#)
        }
        #expect(throws: CompanionTimelinePin.ParseError.nothingToShow) {
            try CompanionTimelinePin.parse(#"{"id": "x", "time": "2026-09-22T08:15:00Z", "layout": {"type": "genericPin"}}"#)
        }
    }

    /// The identifier is a digest, so the same pin id from the same app names
    /// the same pin across launches — and never another app's.
    @Test func thePinsIdentityIsStableAndOwned() {
        let appA = UUID()
        let appB = UUID()

        #expect(
            CompanionTimelinePin.pinID(applicationID: appA, backingID: "bus-42")
                == CompanionTimelinePin.pinID(applicationID: appA, backingID: "bus-42")
        )
        #expect(
            CompanionTimelinePin.pinID(applicationID: appA, backingID: "bus-42")
                != CompanionTimelinePin.pinID(applicationID: appB, backingID: "bus-42")
        )
        #expect(
            CompanionTimelinePin.pinID(applicationID: appA, backingID: "bus-42")
                != CompanionTimelinePin.pinID(applicationID: appA, backingID: "bus-43")
        )
    }

    private func makeModel(directory: URL) -> AppModel {
        AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func webPin(id: String, title: String) throws -> CompanionTimelinePin {
        try CompanionTimelinePin.parse("""
        {"id": "\(id)", "time": "2026-09-22T08:15:00Z", "layout": {"type": "genericPin", "title": "\(title)"}}
        """)
    }

    /// Inserting the same pin id again is the update the web API promises,
    /// not a second pin beside the first.
    @Test func theSamePinInsertedAgainIsAnUpdate() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        let application = UUID()

        await model.insertCompanionTimelinePin(try webPin(id: "bus-42", title: "Bus 42"), applicationID: application)
        await model.insertCompanionTimelinePin(try webPin(id: "bus-42", title: "Bus 42 (delayed)"), applicationID: application)

        let pins = model.timeline.pins.filter { $0.parentApplicationID == application }
        #expect(pins.count == 1)
        #expect(pins.first?.title == "Bus 42 (delayed)")
    }

    /// One app's delete can only reach its own pins: the identity carries the
    /// owner, so the same pin id from another app is another pin.
    @Test func aDeleteReachesOnlyTheAskersOwnPin() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        let owner = UUID()
        let bystander = UUID()
        await model.insertCompanionTimelinePin(try webPin(id: "bus-42", title: "Mine"), applicationID: owner)
        await model.insertCompanionTimelinePin(try webPin(id: "bus-42", title: "Theirs"), applicationID: bystander)

        await model.deleteCompanionTimelinePin(backingID: "bus-42", applicationID: owner)

        #expect(model.timeline.pins.filter { $0.parentApplicationID == owner }.isEmpty)
        #expect(model.timeline.pins.filter { $0.parentApplicationID == bystander }.count == 1)
    }
}
