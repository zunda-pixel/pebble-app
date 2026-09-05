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
        model.health.feedback = nil
        model.catalog.feedback = nil

        await model.addTimelinePin(title: "Stand up", date: Date(timeIntervalSince1970: 1_788_393_600))

        #expect(model.timeline.feedback == .success("Timeline pin saved."))
        // These are the two screens the answer used to land on.
        #expect(model.health.feedback == nil)
        #expect(model.catalog.feedback == nil)
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

        #expect(model.timeline.feedback == .failure("The timeline pin could not be saved."))
        #expect(model.timeline.feedback?.isFailure == true)
        #expect(model.timeline.pins.isEmpty)
    }

    /// Health keeps its own, and it is a success rather than bare words.
    @Test func deletingHealthDataAnswersOnHealthAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.deleteHealthData()

        #expect(model.health.feedback == .success("Local Pebble health data deleted."))
        #expect(model.health.feedback?.isFailure == false)
        #expect(model.timeline.feedback == nil)
        #expect(model.catalog.feedback == nil)
    }

    /// The catalog too, which shared `dataSync` with health.
    @Test func aCatalogURLThatIsNotHTTPSAnswersOnTheCatalogAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.updateCatalog(source: "http://example.com/catalog.json")

        #expect(model.catalog.feedback == .failure("Enter a valid HTTPS catalog URL."))
        #expect(model.health.feedback == nil)
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

        #expect(model.watches.resetFeedback[watch.id] == .progress("The watch is restarting."))
        #expect(model.watches.resetFeedback[watch.id]?.isFailure == false)
    }

    @Test func theWordsComeBackWhicheverKindItIs() {
        #expect(FeatureFeedback.progress("Working…").message == "Working…")
        #expect(FeatureFeedback.success("Done.").message == "Done.")
        #expect(FeatureFeedback.failure("No.").message == "No.")
        #expect(FeatureFeedback.progress("Working…").isFailure == false)
        #expect(FeatureFeedback.success("Done.").isFailure == false)
        #expect(FeatureFeedback.failure("No.").isFailure == true)
    }

    /// Which settings pages may be opened.
    ///
    /// `https` alone refused two of the reader's applications — 91 Dub 4.0 and
    /// AgroWeatherApp — whose pages the official app opens without checking
    /// anything. What is left refused is what a settings page never needs.
    @Test func aSettingsPageMayBePlainButNotHostlessOrCredentialled() throws {
        #expect(AppModel.mayOpenConfigurationURL(try #require(URL(string: "https://example.com/settings"))))
        #expect(AppModel.mayOpenConfigurationURL(try #require(URL(string: "http://example.com/settings"))))
        #expect(AppModel.mayOpenConfigurationURL(try #require(URL(string: "HTTP://example.com/settings"))))

        // No host: a path with a scheme in front of it, not a page.
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "http:///settings"))))
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "file:///etc/passwd"))))
        // The scheme the web view uses to say the page is finished is not one to
        // open a page with.
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "pebblejs://close#%7B%7D"))))
        // Credentials in the URL: the page is asking to be someone.
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "https://user:pw@example.com/s"))))
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "https://user@example.com/s"))))
    }

    @Test func aSettingsPageThatIsRefusedAnswersOnTheApplicationsScreenAlone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        model.openConfigurationURL(try #require(URL(string: "file:///etc/passwd")))

        #expect(model.applications.configurationURL == nil)
        #expect(model.applications.libraryFeedback == .failure("The application requested an unsafe settings URL."))
        #expect(model.catalog.feedback == nil)

        // And a plain page is opened rather than refused.
        let plain = try #require(URL(string: "http://example.com/settings"))
        model.openConfigurationURL(plain)
        #expect(model.applications.configurationURL == plain)
    }
}
