import Foundation
import PebbleProtocol
import PebbleTransport
import Testing
@testable import PebbleApp

@MainActor
@Suite
struct ReplyTemplateTests {
    private func model(in directory: URL, replyTemplates: StorageDirectory?) -> AppModel {
        AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            replyTemplateDirectory: replyTemplates
        )
    }

    private func temporaryDirectory() -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    @Test
    func aReaderWhoNeverSetAnyStartsWithASetTheExtensionCanRead() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = StorageDirectory(url: directory.appending(path: "shared"))
        let model = model(in: directory, replyTemplates: shared)

        await model.loadReplyTemplates()

        let templates = try #require(model.notifications.replyTemplates)
        #expect(templates.map(\.text) == AppModel.startingReplyTemplates)
        #expect(try await ReplyTemplateStore(directory: shared).templates() == templates)
    }

    @Test
    func aReaderWhoDeletedEveryOneIsNotGivenTheStartingSetAgain() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = StorageDirectory(url: directory.appending(path: "shared"))
        let model = model(in: directory, replyTemplates: shared)
        await model.loadReplyTemplates()

        await model.removeReplyTemplates(model.notifications.replyTemplates ?? [])
        await model.loadReplyTemplates()

        #expect(model.notifications.replyTemplates == [])
    }

    @Test
    func templatesAreAddedEditedMovedAndRemovedByIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = StorageDirectory(url: directory.appending(path: "shared"))
        let first = ReplyTemplate(text: "OK")
        let second = ReplyTemplate(text: "OK")
        try await ReplyTemplateStore(directory: shared).save([first, second])
        let model = model(in: directory, replyTemplates: shared)
        await model.loadReplyTemplates()

        await model.addReplyTemplate("  Later  ")
        var edited = second
        edited.text = "Sure"
        await model.updateReplyTemplate(edited)
        let later = try #require(model.notifications.replyTemplates?.last)
        await model.moveReplyTemplates([later], before: first)
        await model.removeReplyTemplates([first])

        #expect(model.notifications.replyTemplates?.map(\.text) == ["Later", "Sure"])
        #expect(try await ReplyTemplateStore(directory: shared).templates() == model.notifications.replyTemplates)
    }

    @Test
    func withNowhereTheExtensionCanReadNothingIsShownAsKept() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(in: directory, replyTemplates: nil)
        await model.loadReplyTemplates()

        await model.addReplyTemplate("OK")

        #expect(model.notifications.replyTemplates == [])
        #expect(model.notifications.replyTemplatesFeedback?.isFailure == true)
    }
}
