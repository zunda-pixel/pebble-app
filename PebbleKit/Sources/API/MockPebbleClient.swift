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
            batteryLevel: 84
        )
    }

    public func disconnect(from device: PebbleDevice) async {
        await Task.yield()
    }
}
