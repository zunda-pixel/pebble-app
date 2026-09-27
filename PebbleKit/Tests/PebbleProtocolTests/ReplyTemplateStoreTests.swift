import Foundation
import Testing
@testable import PebbleProtocol

@Suite
struct ReplyTemplateStoreTests {
    private func directory() -> StorageDirectory {
        StorageDirectory(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test
    func templatesNeverSavedAreNotTheSameAsNone() async throws {
        let store = ReplyTemplateStore(directory: directory())

        #expect(try await store.templates() == nil)
        try await store.save([])
        #expect(try await store.templates() == [])
    }

    @Test
    func templatesAreReadBackInTheirOrder() async throws {
        let directory = directory()
        let templates = [ReplyTemplate(text: "On my way"), ReplyTemplate(text: "OK"), ReplyTemplate(text: "OK")]

        try await ReplyTemplateStore(directory: directory).save(templates)

        #expect(try await ReplyTemplateStore(directory: directory).templates() == templates)
    }

    @Test
    func withNowhereToKeepThemNoneAreReadAndSavingSaysSo() async throws {
        let store = ReplyTemplateStore(directory: nil)

        #expect(try await store.templates() == [])
        await #expect(throws: ReplyTemplateStore.ContainerUnavailable()) {
            try await store.save([ReplyTemplate(text: "OK")])
        }
    }
}
