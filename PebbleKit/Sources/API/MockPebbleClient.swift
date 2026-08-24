public import Foundation

@MainActor
public final class MockPebbleClient: PebbleClient {
    public init() {}

    public func scan() async throws -> [DiscoveredPebble] {
        try await Task.sleep(for: .milliseconds(400))

        return [
            DiscoveredPebble(
                id: "mock-flint",
                name: "Pebble 2 Duo",
                model: .pebble2Duo,
                signalStrength: -42
            ),
            DiscoveredPebble(
                id: "mock-emery",
                name: "Pebble Time 2",
                model: .pebbleTime2,
                signalStrength: -57
            ),
            DiscoveredPebble(
                id: "mock-gabbro",
                name: "Pebble Round 2",
                model: .pebbleRound2,
                signalStrength: -68
            ),
        ]
    }

    public func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        try await Task.sleep(for: .milliseconds(500))

        return PebbleDevice(
            id: device.id,
            name: device.name,
            model: device.model,
            firmwareVersion: "v5.0.0-mock",
            batteryLevel: 84,
            serialNumber: "MOCK00000001"
        )
    }

    public func disconnect(from device: PebbleDevice) async {
        await Task.yield()
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {}

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    public func synchronizeTime() async throws {}

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {}

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {}

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {}

    public func registerApplication(_ metadata: PebbleAppMetadata) async throws {}
}
