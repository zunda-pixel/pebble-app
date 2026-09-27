public import Foundation

public enum WatchConnectionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting(watchID: WatchID)
    /// The link is up and the watch has not finished answering. Between a
    /// third of a second and several seconds on a real watch, and the whole
    /// time on one whose protocol service turns out to be unusable.
    case negotiating(watchID: WatchID)
    case connected(ConnectedWatch)
    case reconnecting(watchID: WatchID)
    case failed(WatchConnectionError)
}

/// How far a connect has got, for the part between the link coming up and the
/// watch saying what it is.
///
/// `connect(to:)` resolves one continuation, so without this there is no
/// channel for an intermediate phase: the app only hears the result. The Add
/// Watch sheet said "Connecting…" for the whole handshake, including the
/// several seconds a watch can spend discovering services and opening its
/// transport.
public enum WatchHandshakePhase: Equatable, Sendable {
    /// CoreBluetooth has the link. The watch has said nothing yet, and its
    /// protocol service has not been found.
    case linkOpen
    /// The PPoG session is open, so a frame can be sent. The version request
    /// is on its way and the watch's answer is what finishes the connect.
    case transportOpen
}

public enum WatchClientEvent: Equatable, Sendable {
    case watchUpdated(ConnectedWatch)
    case appFetchRequested(AppFetchRequest)
    case appMessageReceived(AppMessageData)
    case transferProgress(PutBytesTransferProgress)
    case reconnecting(watchID: WatchID)
    case disconnected(WatchConnectionError)
    case healthSyncCompleted(Bool)
    case healthSamplesReceived([WatchHealthSample])
    case timelineActionInvoked(TimelineActionInvocation)
    case appRunStateChanged(AppRunStateEvent)
    case imageRequested(WatchImageRequest)
    case applicationLogReceived(ApplicationLogLine)
}

public enum WatchConnectionError: Error, Equatable, Sendable {
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
    /// iOS is holding the watch's services as they were, and the ones it lists
    /// cannot be used. Elsewhere the phone serves the protocol itself and the
    /// watch connects to that instead; on iOS AccessorySetupKit forbids the
    /// peripheral manager that takes, so forgetting the watch in the system's
    /// settings — which throws the copy away with the bond — is the way back.
    case watchServicesOutOfDate

    /// A link that is gone, or a radio that is off, will not come back
    /// within the few hundred milliseconds a retry waits.
    public var isWorthAnotherAttempt: Bool {
        switch self {
        case .bluetoothUnavailable, .bluetoothUnsupported, .permissionDenied, .disconnected,
             .handshakeKeptFailing, .pairingRemovedByWatch, .watchServicesOutOfDate:
            false
        case .scanAlreadyInProgress, .watchNotFound, .connectionAlreadyInProgress,
             .connectionFailed, .connectionTimedOut, .protocolNegotiationFailed:
            true
        }
    }
}

@MainActor
public protocol WatchClient: Sendable {
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
    func retrieveKnownWatches(_ hints: [WatchConnectionTarget]) async throws -> [DiscoveredWatch]
    /// Opens a link and waits for the watch to say what it is.
    ///
    /// The target, not a scan result: a connect can be aimed at a saved or
    /// bonded watch nothing scanned for, and a target has no fields such a
    /// caller would have to invent.
    ///
    /// `reportingPhase` is called as the handshake passes each stage, on the
    /// main actor, before this returns. A transport with nothing to report
    /// between the two simply never calls it.
    func connect(
        to target: WatchConnectionTarget,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch
    func disconnect(from watch: ConnectedWatch) async
    func send(_ frame: PebbleProtocolFrame) async throws
    func frames() -> AsyncStream<PebbleProtocolFrame>
    func events() -> AsyncStream<WatchClientEvent>
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
        image: EncodedImage?
    ) async throws
    func declineImageKind(token: UInt8, kindValue: UInt8) async throws
    func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws
}

public extension WatchClient {
    /// A transport with no radio to open has nothing to do here.
    func startBluetooth() {}

    /// For the call sites that only want the watch: a reconnect the app did not
    /// ask for, and every test that is not about the handshake.
    func connect(to target: WatchConnectionTarget) async throws -> ConnectedWatch {
        try await connect(to: target, reportingPhase: { _ in })
    }

    /// The scan-result conveniences, so a test can connect to what it scanned
    /// without spelling the conversion.
    func connect(to watch: DiscoveredWatch) async throws -> ConnectedWatch {
        try await connect(to: watch.connectionTarget, reportingPhase: { _ in })
    }

    func connect(
        to watch: DiscoveredWatch,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        try await connect(to: watch.connectionTarget, reportingPhase: reportingPhase)
    }

    func retrieveKnownWatches(_ hints: [WatchConnectionTarget]) async throws -> [DiscoveredWatch] {
        []
    }

    func refreshWatchInformation() async throws {}

    func takeScreenshot() async throws -> WatchScreenshot {
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

public enum PutBytesClientError: Error, Equatable, Sendable {
    case transferAlreadyInProgress
    case firmwareUpdateAlreadyInProgress
}

public enum AppMessageClientError: Error, Equatable, Sendable {
    case negativeAcknowledgement
}

public extension WatchConnectionError {
    var logDescription: String {
        String(describing: self)
    }
}
