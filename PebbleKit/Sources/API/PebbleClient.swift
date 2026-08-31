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

    /// Whether the same request could succeed if it were sent again in a
    /// moment. A link that is gone, or a radio that is off, will not come back
    /// within the few hundred milliseconds a retry waits, so that work belongs
    /// in the queue that waits for the next connection instead of in a loop.
    public var isWorthAnotherAttempt: Bool {
        switch self {
        case .bluetoothUnavailable, .bluetoothUnsupported, .permissionDenied, .disconnected:
            false
        case .scanAlreadyInProgress, .deviceNotFound, .connectionAlreadyInProgress,
             .connectionFailed, .connectionTimedOut, .protocolNegotiationFailed:
            true
        }
    }
}

@MainActor
public protocol PebbleClient: Sendable {
    func scan() async throws -> [DiscoveredPebble]
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
    /// Sends a named file. A language pack goes under the name `lang`, which is
    /// how the firmware knows what it is.
    func installFile(_ bytes: [UInt8], filename: String) async throws
    /// Asks the watch what it is running now. The answer arrives as a
    /// `deviceUpdated` event, which is how a change the watch made — a new
    /// language pack, a firmware slot — becomes visible.
    func refreshDeviceInformation() async throws
    /// Writes one location's forecast into the watch's weather database, and
    /// waits for the watch to say whether it took it.
    func writeWeather(_ report: PebbleWeatherReport) async throws
    func removeWeather(id: UUID) async throws
    func registerApplication(_ metadata: PebbleAppMetadata) async throws
    func unregisterApplication(applicationID: UUID) async throws
}

public extension PebbleClient {
    func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble] {
        []
    }

    /// A transport with nothing to ask does nothing.
    func refreshDeviceInformation() async throws {}
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
    /// A short, untranslated name for diagnostics and logs. The sentence shown
    /// to the reader lives in the UI layer, where it can be localized.
    var logDescription: String {
        String(describing: self)
    }
}
