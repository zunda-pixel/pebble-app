public import Foundation

public enum PebbleConnectionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting(watchID: WatchID)
    case negotiating(watchID: WatchID)
    case connected(ConnectedWatch)
    case reconnecting(watchID: WatchID)
    case failed(PebbleConnectionError)
}

public enum PebbleClientEvent: Equatable, Sendable {
    case watchUpdated(ConnectedWatch)
    case appFetchRequested(AppFetchRequest)
    case appMessageReceived(AppMessageData)
    case transferProgress(PutBytesTransferProgress)
    case reconnecting(watchID: WatchID)
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
    case watchNotFound
    case connectionAlreadyInProgress
    case connectionFailed
    case connectionTimedOut
    case protocolNegotiationFailed
    case disconnected
    /// The link kept coming up and the handshake kept dying, so the app stopped
    /// chasing the watch. Only a person can do anything about this one.
    case handshakeKeptFailing
    /// The phone is holding a bond the watch has thrown away, so every connect
    /// fails at encryption. Nothing here can clear the phone's side of it.
    ///
    /// A watch keeps one bond: pairing it with another phone or computer throws
    /// this one's away, so being taken over reads as this too.
    case pairingRemovedByWatch

    /// A link that is gone, or a radio that is off, will not come back
    /// within the few hundred milliseconds a retry waits.
    public var isWorthAnotherAttempt: Bool {
        switch self {
        case .bluetoothUnavailable, .bluetoothUnsupported, .permissionDenied, .disconnected,
             .handshakeKeptFailing, .pairingRemovedByWatch:
            false
        case .scanAlreadyInProgress, .watchNotFound, .connectionAlreadyInProgress,
             .connectionFailed, .connectionTimedOut, .protocolNegotiationFailed:
            true
        }
    }
}

@MainActor
public protocol PebbleClient: Sendable {
    /// Opens the radio before anything is asked of it.
    ///
    /// Doing this costs the reader the system's permission dialog, so it is not
    /// done at launch on an install with no watch yet: there the dialog would
    /// arrive before they had asked for anything. An install that has a watch
    /// starts here, because a watch that reconnects on its own has to find the
    /// phone ready.
    func startBluetooth()
    func scan() async throws -> [DiscoveredWatch]
    /// A bonded Pebble usually does not advertise, so scanning alone can never
    /// rediscover it; it has to be looked up by its stored identifier.
    func retrieveKnownWatches(_ hints: [DiscoveredWatch]) async throws -> [DiscoveredWatch]
    func connect(to device: DiscoveredWatch) async throws -> ConnectedWatch
    func disconnect(from device: ConnectedWatch) async
    func send(_ frame: PebbleProtocolFrame) async throws
    func frames() -> AsyncStream<PebbleProtocolFrame>
    func events() -> AsyncStream<PebbleClientEvent>
    func synchronizeTime() async throws
    func reorderApplications(_ applicationIDs: [UUID]) async throws
    func respondToAppFetch(with status: AppFetchResponseStatus) async throws
    func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws
    func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws
    /// Writes one record into the watch's databases, in as many frames as the
    /// record takes.
    ///
    /// There used to be twenty of these, one per record, written out in each of
    /// the three transports — and by the time anyone counted, the emulator was
    /// sending seven of them without reading the reply and refusing an
    /// application record the real client accepts. What to send and what counts
    /// as a yes now come from `BlobDBRecord` alone.
    func write(_ record: BlobDBRecord) async throws
    func remove(_ key: BlobDBKey) async throws
    /// Asks the watch for one of its longer answers and waits for the last
    /// piece. Read through `takeScreenshot()`, `readLogGeneration(_:)` or
    /// `getBytes(_:)`, which give the answer back in its own type.
    func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer
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
    func refreshWatchInformation() async throws
    /// A nil image says there is none, which is what lets the watch stop
    /// waiting.
    func sendImage(
        token: UInt8,
        kindValue: UInt8,
        image: PebbleEncodedImage?
    ) async throws
    func declineImageKind(token: UInt8, kindValue: UInt8) async throws
    func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws
}

public extension PebbleClient {
    /// A transport with no radio to open has nothing to do here.
    func startBluetooth() {}

    func retrieveKnownWatches(_ hints: [DiscoveredWatch]) async throws -> [DiscoveredWatch] {
        []
    }

    func refreshWatchInformation() async throws {}

    func takeScreenshot() async throws -> PebbleScreenshot {
        guard case .screenshot(let screenshot) = try await pull(.screenshot) else {
            throw WatchPullError.answeredSomethingElse(.screenshot)
        }
        return screenshot
    }

    /// Generation zero is the run the watch is in now, one the run before it.
    /// Nil once asked for further back than the watch goes.
    func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? {
        guard case .logLines(let lines) = try await pull(.logGeneration(generation)) else {
            throw WatchPullError.answeredSomethingElse(.logGeneration(generation))
        }
        return lines
    }

    func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] {
        guard case .bytes(let bytes) = try await pull(.file(request)) else {
            throw WatchPullError.answeredSomethingElse(.file(request))
        }
        return bytes
    }
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
    /// A transport handed back an answer of another kind. Nothing here can read
    /// it, and guessing at it would report one of the watch's answers as
    /// another's.
    case answeredSomethingElse(WatchPullRequest)
}

public enum AppMessageClientError: Error, Equatable, Sendable {
    case negativeAcknowledgement
}

public extension PebbleConnectionError {
    var logDescription: String {
        String(describing: self)
    }
}
