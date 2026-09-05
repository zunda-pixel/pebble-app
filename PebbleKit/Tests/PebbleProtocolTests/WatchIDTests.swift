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
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
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
}
