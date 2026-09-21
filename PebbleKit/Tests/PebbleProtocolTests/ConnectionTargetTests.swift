import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// What a connect is aimed at carries only what its source really knows.
///
/// The scan type used to double as the connect handle, and every caller that
/// was not a scan had to invent a model and an RSSI to satisfy it — the
/// invented `.pebble2Duo` then stood in for any watch whose platform byte this
/// app cannot map, for the whole session (#121).
@Suite
struct ConnectionTargetTests {
    @Test func aScanResultKeepsItsModel() {
        let discovered = DiscoveredWatch(
            id: WatchID("scanned"),
            name: "Pebble 5209",
            model: .pebbleTime2,
            signalStrength: -60
        )

        #expect(discovered.connectionTarget.model == .pebbleTime2)
        #expect(discovered.connectionTarget.name == "Pebble 5209")
    }

    @Test func aSavedWatchRemembersOrAdmitsItsModel() {
        var saved = SavedWatch(
            id: WatchID("saved"),
            name: "Pebble 33EE",
            model: WatchModel.pebble2Duo,
            firmwareVersion: nil,
            serialNumber: nil,
            lastBatteryLevel: nil,
            lastConnectedAt: Date(timeIntervalSince1970: 100),
            automaticallyConnects: true
        )
        #expect(saved.connectionTarget.model == .pebble2Duo)

        saved.model = nil
        #expect(saved.connectionTarget.model == nil)
    }

    /// The one that used to lie: id and name are all anybody knows.
    @Test func anUnknownBondedWatchInventsNothing() {
        let bonded = UnknownBondedWatch(id: WatchID("bonded"), name: "Pebble")

        #expect(bonded.connectionTarget.model == nil)
    }

    /// A looked-up watch was not heard advertising, so what comes back says
    /// nil where a scan would have measured — no more "0 dBm" rows.
    @MainActor
    @Test func aRetrievedWatchHasNoInventedSignal() async throws {
        let client = MockWatchClient()
        let target = WatchConnectionTarget(id: WatchID("bonded"), name: "Pebble", model: nil)

        let retrieved = try await client.retrieveKnownWatches([target])

        let watch = try #require(retrieved.first)
        #expect(watch.signalStrength == nil)
        #expect(watch.model == nil)
        #expect(watch.name == "Pebble")
    }
}
