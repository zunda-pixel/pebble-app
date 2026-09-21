import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// Links the app is opened with: what each one asks for, what is refused by
/// name, and the rule that nothing a link carries reaches a watch on the
/// link's say-so alone.
@Suite
@MainActor
struct DeepLinkTests {
    private func parsed(_ string: String) -> Result<PebbleDeepLink, PebbleDeepLink.Refusal> {
        PebbleDeepLink.parse(URL(string: string)!)
    }

    @Test func theNavigationLinksNameTheirSections() {
        #expect(parsed("pebble://navbar/apps") == .success(.section(.apps)))
        #expect(parsed("pebble://navbar/health") == .success(.section(.health)))
        #expect(parsed("pebble://show-watches") == .success(.section(.watches)))
        // The official app's update notification carries the watch's serial;
        // showing the list is the useful part and the serial is dropped.
        #expect(parsed("pebble://show-watches/C1112811035V") == .success(.section(.watches)))
    }

    @Test func aStoreLinkCarriesTheStoresOwnIdentifier() {
        #expect(parsed("pebble://appstore/52ce8a2a3ea") == .success(.storeApplication(id: "52ce8a2a3ea")))
        // The official app names a feed in the query; until #97 the selected
        // source answers, and naming one is not a reason to refuse the link.
        #expect(
            parsed("pebble://appstore/52ce8a2a3ea?source=https%3A%2F%2Fexample.com")
                == .success(.storeApplication(id: "52ce8a2a3ea"))
        )
        #expect(parsed("pebble://appstore") == .failure(.unknown))
        #expect(parsed("pebble://appstore/a/b") == .failure(.unknown))
    }

    @Test func aPackageLinkIsTypedByItsExtensionAndMustBeHTTPS() {
        let watchApp = URL(string: "https://example.com/apps/runcat.pbw")!
        #expect(PebbleDeepLink.parse(watchApp) == .success(.package(.watchApp, watchApp)))
        let firmware = URL(string: "https://example.com/fw/obelix.pbz")!
        #expect(PebbleDeepLink.parse(firmware) == .success(.package(.firmware, firmware)))
        let language = URL(string: "https://example.com/lang/ja.pbl")!
        #expect(PebbleDeepLink.parse(language) == .success(.package(.languagePack, language)))
        // A package is code the watch will run; over plain http it would
        // arrive rewritable.
        #expect(parsed("http://example.com/apps/runcat.pbw") == .failure(.insecurePackageSource))
        // An https page that is not a package is a page, not a deep link.
        #expect(parsed("https://example.com/apps/runcat") == .failure(.unknown))
    }

    @Test func whatThisAppCannotHonourIsRefusedByName() {
        #expect(parsed("pebble://add-store-feed/Rebble/https%3A%2F%2Fexample.com") == .failure(.storeFeedsNotSupported))
        #expect(parsed("pebble://custom-boot-config-url/x?access_token=abc&t=1") == .failure(.accountsNotSupported))
        #expect(parsed("pebblejs://close#settings") == .failure(.configurationSessionOnly))
        #expect(parsed("pebble://navbar/index") == .failure(.unknown))
        #expect(parsed("pebble://something-else") == .failure(.unknown))
        #expect(parsed("mailto:someone@example.com") == .failure(.unknown))
    }

    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
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

    /// The link's package is fetched and read, and then it waits: the library
    /// takes nothing until the reader has seen what it is and said install.
    @Test func aLinkedPackageWaitsForTheReaderAndInstallsOnTheirWord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())
        let applicationID = UUID()
        let package = try makeApplicationPackage(
            in: directory,
            applicationID: applicationID,
            versionLabel: "2.5"
        )

        await model.openDeepLink(package)

        let pending = try #require(model.deepLinks.pendingPackage)
        #expect(pending.kind == .watchApp)
        #expect(pending.subtitle?.contains("2.5") == true)
        #expect(pending.byteCount > 0)
        #expect(model.applications.apps.isEmpty && model.applications.watchfaces.isEmpty)

        await model.confirmPendingDeepLinkPackage()

        #expect(model.deepLinks.pendingPackage == nil)
        #expect(model.deepLinks.requestedSection == .apps)
        #expect((model.applications.apps + model.applications.watchfaces).contains { $0.id == applicationID })
    }

    /// Waved away, the offer leaves nothing behind: no pending state and no
    /// copy of a package nobody wanted.
    @Test func aDismissedOfferDeletesItsCopy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())
        let package = try makeApplicationPackage(in: directory, applicationID: UUID(), versionLabel: "1.0")
        await model.openDeepLink(package)
        let copy = try #require(model.deepLinks.pendingPackage).localURL

        model.dismissPendingDeepLinkPackage()

        #expect(model.deepLinks.pendingPackage == nil)
        #expect(!FileManager.default.fileExists(atPath: copy.path()))
        #expect((model.applications.apps + model.applications.watchfaces).isEmpty)
    }

    /// A link to a file that is not a watch app is answered with a failure and
    /// no pending offer — refused before the sheet, not after the install.
    @Test func aFileThatIsNotAPackageIsRefusedBeforeTheSheet() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())
        let impostor = directory.appending(path: "impostor.pbw")
        try Data("not a zip archive".utf8).write(to: impostor)

        await model.openDeepLink(impostor)

        #expect(model.deepLinks.pendingPackage == nil)
        #expect(model.deepLinks.feedback?.isFailure == true)
    }

    /// A refused link says why, and a navigation link is taken at once — a tab
    /// is where the reader was going, not a transfer to confirm.
    @Test func navigationIsImmediateAndRefusalsSpeak() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory, client: MockWatchClient())

        await model.openDeepLink(URL(string: "pebble://navbar/timeline")!)
        #expect(model.deepLinks.requestedSection == .timeline)
        model.consumeRequestedDeepLinkSection()
        #expect(model.deepLinks.requestedSection == nil)

        await model.openDeepLink(URL(string: "pebble://add-store-feed/a/b")!)
        #expect(model.deepLinks.feedback?.isFailure == true)
    }
}
