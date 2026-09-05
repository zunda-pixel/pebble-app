@testable import PebbleTransport
import Foundation
// The words in a `FeatureFeedback` are a `LocalizedStringKey`, and under
// `MemberImportVisibility` its literal initializer needs the module that
// declares it.
import SwiftUI
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// Which feature each answer belongs to, and whether it went well.
///
/// Both used to be untyped. Twelve `LocalizedStringKey?` properties under two
/// names that did not reliably mean anything, one of which — `dataSync` — was
/// written by four features and read by two screens. The result was that
/// saving a timeline pin put its answer on the Health and Catalog screens, and
/// the Timeline screen, which had asked, showed nothing (#60).
@Suite
@MainActor
struct FeatureFeedbackTests {
    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            clientFactory: { _ in client }
        )
    }

    /// The regression: a pin's answer is the timeline's, and nobody else's.
    @Test func savingATimelinePinAnswersOnTheTimelineAndNowhereElse() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        // Connecting asks the watch to synchronize its health, which is its own
        // feature answering for itself. What is under test is what saving a pin
        // adds to that.
        model.healthFeedback = nil
        model.catalogFeedback = nil

        await model.addTimelinePin(title: "Stand up", date: Date(timeIntervalSince1970: 1_788_393_600))

        #expect(model.timelineFeedback == .success("Timeline pin saved."))
        // These are the two screens the answer used to land on.
        #expect(model.healthFeedback == nil)
        #expect(model.catalogFeedback == nil)
    }

    /// A pin that could not be saved is a failure, not a status: the reader who
    /// asked for it has to be able to tell.
    @Test func aPinThatCouldNotBeSavedIsAFailure() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        // A directory where the file should be: the write cannot succeed, and
        // nothing else about the model is unusual.
        try FileManager.default.createDirectory(
            at: directory.appending(path: "timeline.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        await model.addTimelinePin(title: "Stand up", date: Date(timeIntervalSince1970: 1_788_393_600))

        #expect(model.timelineFeedback == .failure("The timeline pin could not be saved."))
        #expect(model.timelineFeedback?.isFailure == true)
        #expect(model.timelinePins.isEmpty)
    }

    /// Health keeps its own, and it is a success rather than bare words.
    @Test func deletingHealthDataAnswersOnHealthAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.deleteHealthData()

        #expect(model.healthFeedback == .success("Local Pebble health data deleted."))
        #expect(model.healthFeedback?.isFailure == false)
        #expect(model.timelineFeedback == nil)
        #expect(model.catalogFeedback == nil)
    }

    /// The catalog too, which shared `dataSync` with health.
    @Test func aCatalogURLThatIsNotHTTPSAnswersOnTheCatalogAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.updateCatalog(source: "http://example.com/catalog.json")

        #expect(model.catalogFeedback == .failure("Enter a valid HTTPS catalog URL."))
        #expect(model.healthFeedback == nil)
    }

    /// A watch asked to restart is under way, not finished: the only news
    /// afterwards is the link returning, so a success would be a lie.
    @Test func aWatchToldToRestartReadsAsProgress() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let watch = try #require(model.discoveredWatches.first)
        await model.connect(to: watch)

        await model.resetWatch(.restart, watchID: watch.id)

        #expect(model.watchResetFeedback[watch.id] == .progress("The watch is restarting."))
        #expect(model.watchResetFeedback[watch.id]?.isFailure == false)
    }

    @Test func theWordsComeBackWhicheverKindItIs() {
        #expect(FeatureFeedback.progress("Working…").message == "Working…")
        #expect(FeatureFeedback.success("Done.").message == "Done.")
        #expect(FeatureFeedback.failure("No.").message == "No.")
        #expect(FeatureFeedback.progress("Working…").isFailure == false)
        #expect(FeatureFeedback.success("Done.").isFailure == false)
        #expect(FeatureFeedback.failure("No.").isFailure == true)
    }
}
