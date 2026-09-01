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
    case imageRequested(PebbleImageRequest)
    case applicationLogReceived(applicationID: UUID, line: WatchLogLine)
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

    /// A link that is gone, or a radio that is off, will not come back
    /// within the few hundred milliseconds a retry waits.
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
    /// A bonded Pebble usually does not advertise, so scanning alone can never
    /// rediscover it; it has to be looked up by its stored identifier.
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
    func upsertTimelineReminder(_ reminder: PebbleTimelinePin) async throws
    func deleteTimelineReminder(id: UUID) async throws
    func launchApplication(id: UUID) async throws
    func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws
    func installFirmware(_ package: PBZFirmwarePackage) async throws
    /// A language pack goes under the name `lang`, which is how the firmware
    /// knows what it is.
    func installFile(_ bytes: [UInt8], filename: String) async throws
    func refreshDeviceInformation() async throws
    func writeNotificationSourceApp(_ app: NotificationSourceApp) async throws
    func removeNotificationSourceApp(bundleID: String) async throws
    func writeWeather(_ report: PebbleWeatherReport) async throws
    func removeWeather(id: UUID) async throws
    /// A forecast the watch holds but this list does not name is not shown.
    func writeWeatherLocationOrder(_ orderedIDs: [UUID]) async throws
    /// Only the settings the firmware lists as syncable are accepted.
    func writeWatchSetting(_ setting: WatchSetting, isOn: Bool) async throws
    func writeActivitySettings(_ settings: PebbleActivitySettings) async throws
    func writeHeartRateSettings(_ settings: PebbleHeartRateSettings) async throws
    func writeHealthDay(_ day: PebbleHealthDay) async throws
    func writeReminderAppState(_ state: PebbleReminderAppState) async throws
    /// A nil image says there is none, which is what lets the watch stop
    /// waiting.
    func sendImage(
        token: UInt8,
        kindValue: UInt8,
        image: PebbleEncodedImage?
    ) async throws
    func declineImageKind(token: UInt8, kindValue: UInt8) async throws
    func takeScreenshot() async throws -> PebbleScreenshot
    /// Generation zero is the run the watch is in now, one the run before it.
    /// Nil once asked for further back than the watch goes.
    func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]?
    func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws
    func getBytes(_ request: GetBytesRequest) async throws -> [UInt8]
    func registerApplication(_ metadata: PebbleAppMetadata) async throws
    func unregisterApplication(applicationID: UUID) async throws
}

public extension PebbleClient {
    func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble] {
        []
    }

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

public enum WatchPullError: Error, Equatable, Sendable {
    case operationAlreadyInProgress
    case notSupported
}

public enum AppMessageClientError: Error, Equatable, Sendable {
    case negativeAcknowledgement
}

public extension PebbleConnectionError {
    var logDescription: String {
        String(describing: self)
    }
}
