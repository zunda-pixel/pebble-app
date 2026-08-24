import API
import Foundation
import Testing
@testable import UI

@Suite
@MainActor
struct UITests {
    @Test
    func appModelScansConnectsAndSynchronizesEmptyLibrary() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(client: client, applicationLibrary: library)

        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        #expect(model.connectedDevice?.id == discovered.id)
        #expect(model.applicationManagementOperation == nil)
        #expect(client.reorderedApplicationIDs.last == [])
    }

    @Test
    func appModelRejectsAppMessageForUnknownApplication() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(client: client, applicationLibrary: library)
        await model.scan()
        let discovered = try #require(model.discoveredDevices.first)
        await model.connect(to: discovered)

        client.emit(.appMessageReceived(AppMessageData(
            transactionID: 17,
            applicationID: UUID(),
            tuples: []
        )))
        await Task.yield()
        try await Task.sleep(for: .milliseconds(20))

        #expect(client.appMessageResponses.contains {
            $0.transactionID == 17 && !$0.acknowledged
        })
    }
}
