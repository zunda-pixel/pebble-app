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

    /// Update All answers where its button is, which is the applications
    /// screen.
    ///
    /// It used to answer on `catalog.feedback` while its button sat in the
    /// catalogue's toolbar — and the catalogue has no feedback banner, so the
    /// words went nowhere. Pressing it and being told nothing at all is the
    /// same shape of fault as #60, one screen further along.
    @Test func installingCatalogUpdatesAnswersOnTheApplicationsScreen() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        // Nothing in the catalogue, so nothing to update — the answer a reader
        // gets most often, and the one that used to be silent.
        await model.installCatalogUpdates()

        #expect(model.applications.managementFeedback == .success("Installed apps are up to date."))
        #expect(model.applications.managementFeedback?.isFailure == false)
        #expect(model.catalog.feedback == nil)
        #expect(model.applications.libraryFeedback == nil)
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

    /// What a settings page is named by in the log.
    ///
    /// The page was loaded twice for one opening on the reader's phone and
    /// nothing could say whether that was two URLs or one, because only a
    /// refusal was ever recorded. Naming it is the difference — and it has to be
    /// a fingerprint: the query string carries the watch token and the reader's
    /// account, which is why a refusal names the rule it broke and not the
    /// address.
    @Test func aSettingsPageIsNamedInTheLogByAFingerprintAndNotItsAddress() throws {
        let withToken = try #require(URL(string: "https://example.com/s?token=abc123&account=reader@example.com"))
        let fingerprint = AppModel.configurationFingerprint(withToken)

        // Short enough to read at a glance, and the same URL always gives it.
        #expect(fingerprint.count == 8)
        #expect(AppModel.configurationFingerprint(withToken) == fingerprint)
        // Nothing of the URL survives into it.
        #expect(!fingerprint.contains("abc123"))
        #expect(!fingerprint.contains("example"))

        // Two pages that differ at all are told apart, which is the whole point:
        // one fingerprint twice is a view reloading, two is two URLs arriving.
        let other = try #require(URL(string: "https://example.com/s?token=abc124&account=reader@example.com"))
        #expect(AppModel.configurationFingerprint(other) != fingerprint)
    }

    /// A settings page an application built itself and handed over inline.
    ///
    /// AgroWeatherApp's is one of these — `scheme=data host=none` in the log —
    /// and it is a page, not a URL with something missing from it.
    @Test func aPageHandedOverInlineIsUnpackedRatherThanNavigatedTo() throws {
        let plain = try #require(URL(string: "data:text/html,%3Ch1%3ESettings%3C%2Fh1%3E"))
        #expect(plain.inlineHTML == "<h1>Settings</h1>")
        #expect(AppModel.mayOpenConfigurationURL(plain))

        // Base64, which is the other way an application sends its page.
        let encoded = try #require(URL(string: "data:text/html;base64,PGgxPlNldHRpbmdzPC9oMT4="))
        #expect(encoded.inlineHTML == "<h1>Settings</h1>")
        #expect(AppModel.mayOpenConfigurationURL(encoded))

        // No media type at all: RFC 2397 calls that text/plain, and
        // applications leave it off while sending markup all the same.
        let bare = try #require(URL(string: "data:,%3Cp%3EHello%3C%2Fp%3E"))
        #expect(bare.inlineHTML == "<p>Hello</p>")

        // Not a page: rendering an image as markup would be a guess.
        #expect(try #require(URL(string: "data:image/png;base64,iVBORw0K")).inlineHTML == nil)
        #expect(!AppModel.mayOpenConfigurationURL(try #require(URL(string: "data:image/png;base64,iVBORw0K"))))
        // Base64 that is not base64 decodes to nothing, and a page with nothing
        // in it is not a page.
        #expect(try #require(URL(string: "data:text/html;base64,!!!!")).inlineHTML == nil)
        #expect(try #require(URL(string: "data:text/html,")).inlineHTML == nil)
        // Nothing to separate the header from the payload.
        #expect(try #require(URL(string: "data:text/html")).inlineHTML == nil)
        // And an ordinary page is not an inline one.
        #expect(try #require(URL(string: "https://example.com/s")).inlineHTML == nil)
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

    /// The page the sheet showing it belongs to.
    ///
    /// Presented on whether a page was showing at all, with the page picked out
    /// by an `if let` inside, the web view was built twice for one opening: the
    /// contents were tied to nothing, so there was nothing to keep them. On the
    /// reader's phone that was two loads 69 ms apart, the second still going
    /// 3.35 seconds later with the first thrown away, against 2.0 seconds for
    /// the one that ran alone.
    @Test func theSheetShowingASettingsPageBelongsToThatPage() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        #expect(model.applications.configurationPage == nil)

        let first = try #require(URL(string: "http://example.com/settings?token=one"))
        model.openConfigurationURL(first)
        #expect(model.applications.configurationPage?.id == first)

        // The same page again is the same sheet, which is what keeps the web
        // view rather than building a second one.
        model.openConfigurationURL(first)
        #expect(model.applications.configurationPage?.id == first)
        #expect(ConfigurationPage(url: first) == ConfigurationPage(url: first))

        // A different page is a different one, so it is built rather than kept.
        let second = try #require(URL(string: "http://example.com/settings?token=two"))
        model.openConfigurationURL(second)
        #expect(model.applications.configurationPage?.id == second)

        // A page that is refused never becomes a sheet at all.
        model.openConfigurationURL(try #require(URL(string: "file:///etc/passwd")))
        #expect(model.applications.configurationPage?.id == second)
    }
}
