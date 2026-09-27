@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// What the app says while a watch is connecting.
///
/// `.negotiating` existed and was never assigned: `connect(to:)` resolves one
/// continuation and the app only heard the result, so the Add Watch sheet said
/// "Connecting…" for the whole handshake — including the several seconds a
/// watch can spend discovering services and opening its transport, and the
/// whole of a connect to a watch whose protocol service turns out to be
/// unusable.
@Suite
@MainActor
struct HandshakeStateTests {
    private func makeModel(directory: URL, client: MockWatchClient) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            clientFactory: { _ in client }
        )
    }

    @Test func theHandshakeIsReportedBetweenConnectingAndConnected() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let watch = try #require(model.discoveredWatches.first)

        // Sampled inside the connect rather than polled beside it: the app's
        // reporter runs synchronously, so by the time the transport is back
        // from reporting a phase the state has already moved.
        var sampled: [WatchHandshakePhase: WatchConnectionState] = [:]
        client.afterReportingPhase = { phase in sampled[phase] = model.connectionState }

        #expect(model.connectionState == .idle)
        await model.connect(to: watch)

        // What the Add Watch sheet would have drawn, and used to draw as
        // "Connecting…" for the whole of both.
        #expect(sampled[.linkOpen] == .negotiating(watchID: watch.id))
        #expect(sampled[.transportOpen] == .negotiating(watchID: watch.id))
        #expect(model.connectedWatch?.id == watch.id)
    }

    /// Both phases reach the transport's caller, in order. The app shows one
    /// state for the span between them, but a watch that reaches the first and
    /// never the second is one whose protocol service is unusable, and that
    /// distinction has to survive to the log.
    @Test func bothPhasesAreReportedInOrder() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()

        await model.connect(to: try #require(model.discoveredWatches.first))

        #expect(client.reportedHandshakePhases == [.linkOpen, .transportOpen])
    }

    /// The state does not stay in the handshake once the watch has answered,
    /// nor after a connect that failed.
    @Test func aFinishedConnectLeavesTheHandshakeBehind() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let watch = try #require(model.discoveredWatches.first)

        await model.connect(to: watch)
        #expect(model.connectionState == .connected(try #require(model.connectedWatch)))
        #expect(model.negotiatingWatchIDs.isEmpty)

        let refusing = MockWatchClient()
        refusing.connectionFailure = .protocolNegotiationFailed
        let second = AppModel(
            client: refusing,
            storageDirectory: StorageDirectory(url: directory.appending(path: "second")),
            clientFactory: { _ in refusing }
        )
        await second.scan()
        await second.connect(to: try #require(second.discoveredWatches.first))

        #expect(second.connectionState == .failed(.protocolNegotiationFailed))
        #expect(second.negotiatingWatchIDs.isEmpty)
    }
}
