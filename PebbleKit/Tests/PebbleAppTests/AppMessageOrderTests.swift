import PebbleProtocol
@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleApp

/// Messages from a watch app reach its script in the order the watch sent them.
@Suite
@MainActor
struct AppMessageOrderTests {
    @MainActor
    private final class Record {
        var steps: [String] = []
    }

    private func message(_ transactionID: UInt8) -> AppMessageData {
        AppMessageData(transactionID: transactionID, applicationID: UUID(), tuples: [])
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowMessageIsFinishedBeforeTheNextOneStarts() async throws {
        let client = MockWatchClient()
        let connection = WatchConnection(
            client: client,
            watch: ConnectedWatch(
                id: WatchID("mock-emery"),
                name: "Pebble Time 2",
                model: .pebbleTime2,
                batteryLevel: nil,
                version: WatchVersionInformation(firmwareVersion: "v5.0.0", serialNumber: nil, hardwarePlatform: 18)
            )
        )
        let record = Record()
        connection.startObserving(
            onEvent: { _, _ in },
            onFrame: { _, _ in },
            onAppMessage: { _, message in
                record.steps.append("start \(message.transactionID)")
                if message.transactionID == 1 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                record.steps.append("end \(message.transactionID)")
            }
        )
        // Long enough for the observing task to have asked for the events.
        try await Task.sleep(for: .milliseconds(50))

        client.emit(.appMessageReceived(message(1)))
        client.emit(.appMessageReceived(message(2)))
        while record.steps.count < 4 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(record.steps == ["start 1", "end 1", "start 2", "end 2"])
        await connection.close()
    }
}
