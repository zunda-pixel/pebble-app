public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleReconnectBackoff: Equatable, Sendable {
    public var attempt: Int = 0
    public var initialDelay: Duration = .seconds(2)
    public var maximumDelay: Duration = .seconds(30)

    public mutating func nextDelay() -> Duration {
        let multiplier = 1 << min(attempt, 10)
        let delay = min(initialDelay * multiplier, maximumDelay)
        attempt = min(attempt + 1, 10)
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}

public enum PebbleConnectionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting(deviceID: String)
    case negotiating(deviceID: String)
    case connected(PebbleDevice)
    case reconnecting(deviceID: String)
    case failed(PebbleConnectionError)
}

public enum PebbleClientEvent: Equatable, Sendable {
    case deviceUpdated(PebbleDevice)
    case appFetchRequested(AppFetchRequest)
    case appMessageReceived(AppMessageData)
    case transferProgress(PutBytesTransferProgress)
    case reconnecting(deviceID: String)
    case disconnected(PebbleConnectionError)
    case healthSyncCompleted(Bool)
    case healthSamplesReceived([PebbleHealthSample])
    case timelineActionInvoked(TimelineActionInvocation)
    case appRunStateChanged(AppRunStateEvent)
}

public enum PebbleConnectionError: Error, Equatable, Sendable {
    case bluetoothUnavailable
    case bluetoothUnsupported
    case permissionDenied
    case scanAlreadyInProgress
    case deviceNotFound
    case connectionAlreadyInProgress
    case connectionFailed
    case connectionTimedOut
    case protocolNegotiationFailed
    case disconnected
}

@MainActor
public protocol PebbleClient: Sendable {
    func scan() async throws -> [DiscoveredPebble]
    /// Keeps the radio scanning until every caller has stopped, so results can
    /// be observed continuously instead of in short bursts.
    func startScanning() async throws
    func stopScanning()
    func currentScanResults() -> [DiscoveredPebble]
    /// Makes previously paired watches connectable again without a scan.
    /// A bonded Pebble usually does not advertise, so scanning alone can
    /// never rediscover it; implementations look the watches up by their
    /// stored identifiers instead. Returns the hints that were found.
    func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble]
    func connect(to device: DiscoveredPebble) async throws -> PebbleDevice
    func disconnect(from device: PebbleDevice) async
    func send(_ frame: PebbleProtocolFrame) async throws
    func frames() -> AsyncStream<PebbleProtocolFrame>
    func events() -> AsyncStream<PebbleClientEvent>
    func synchronizeTime() async throws
    func reorderApplications(_ applicationIDs: [UUID]) async throws
    func respondToAppFetch(with status: AppFetchResponseStatus) async throws
    func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws
    func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws
    func sendNotification(_ notification: PebbleTimelineNotification) async throws
    func upsertTimelinePin(_ pin: PebbleTimelinePin) async throws
    func deleteTimelinePin(id: UUID) async throws
    func launchApplication(id: UUID) async throws
    func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws
    func installFirmware(_ package: PBZFirmwarePackage) async throws
    func registerApplication(_ metadata: PebbleAppMetadata) async throws
    func unregisterApplication(applicationID: UUID) async throws
}

public extension PebbleClient {
    func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble] {
        []
    }

    func startScanning() async throws {}
    func stopScanning() {}
    func currentScanResults() -> [DiscoveredPebble] { [] }
}

public enum BlobDBClientError: Error, Equatable, Sendable {
    case operationAlreadyInProgress
    case rejected(BlobDBStatus)
}

public enum AppReorderClientError: Error, Equatable, Sendable {
    case operationAlreadyInProgress
    case rejected(AppReorderResult)
}

public enum AppMessageClientError: Error, Equatable, Sendable {
    case negativeAcknowledgement
}

public extension PebbleConnectionError {
    var message: String {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is turned off or temporarily unavailable."
        case .bluetoothUnsupported:
            "Bluetooth Low Energy is not supported on this device."
        case .permissionDenied:
            "Bluetooth access is not allowed. Enable it in System Settings."
        case .scanAlreadyInProgress:
            "A watch scan is already in progress."
        case .deviceNotFound:
            "The selected watch is no longer available. Scan again."
        case .connectionAlreadyInProgress:
            "Another watch connection is already in progress."
        case .connectionFailed:
            "The watch connection failed. Move the watch closer and try again."
        case .connectionTimedOut:
            "The watch did not respond in time."
        case .protocolNegotiationFailed:
            "The watch does not expose the expected Pebble connection service."
        case .disconnected:
            "The watch disconnected."
        }
    }
}
