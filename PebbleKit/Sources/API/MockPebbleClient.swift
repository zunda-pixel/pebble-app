public import Foundation

@MainActor
public final class MockPebbleClient: PebbleClient {
    public private(set) var sentFrames: [PebbleProtocolFrame] = []
    public private(set) var sentAppMessages: [AppMessageData] = []
    public private(set) var appMessageResponses: [(transactionID: UInt8, acknowledged: Bool)] = []
    public private(set) var reorderedApplicationIDs: [[UUID]] = []
    private var nextTransactionID: UInt8 = 0
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?

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

    public func send(_ frame: PebbleProtocolFrame) async throws {
        sentFrames.append(frame)
    }

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in
            frameContinuation = continuation
        }
    }

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {}

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        reorderedApplicationIDs.append(applicationIDs)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {}

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        sentAppMessages.append(AppMessageData(
            transactionID: nextTransactionID,
            applicationID: applicationID,
            tuples: tuples
        ))
        nextTransactionID &+= 1
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        appMessageResponses.append((transactionID, acknowledged))
    }

    public func emit(_ frame: PebbleProtocolFrame) {
        frameContinuation?.yield(frame)
    }

    public func emit(_ event: PebbleClientEvent) {
        eventContinuation?.yield(event)
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {}

    public func registerApplication(_ metadata: PebbleAppMetadata) async throws {}

    public func unregisterApplication(applicationID: UUID) async throws {}
}
