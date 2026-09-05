public import PebbleProtocol
public import CoreBluetooth
import DequeModule
public import Foundation
import MemberwiseInit

private final class NotificationObserverStorage: @unchecked Sendable {
    var observers: [any NSObjectProtocol] = []

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// What is left here is the link: the radio, the handshake, the PPoG session,
/// the frame dispatch and the health check that decides a link has died. What
/// the watch is *asked* for lives beside it — `+Records` for the BlobDB writes
/// and the transfers, `+Pulls` for the three longer answers — and the two
/// delegate conformances in `+Central` and `+Peripheral`.
///
/// Swift has no access level for "this type across its files", so everything
/// those four files touch is `internal` rather than `private`. That is the
/// price of the split, and it was worth paying only once the twenty typed
/// BlobDB methods had collapsed into `write(_:)` and `remove(_:)`: before
/// that, the records and the link were interleaved and there was no seam to
/// cut along. `internal` reaches no further than this module.
@MainActor
public final class CoreBluetoothWatchClient: NSObject, WatchClient {
    static var ppogService = CBUUID(string: "40000000-328E-0FBB-C642-1AA6699BDADA")
    /// Advertised by watches that are not bonded yet, including after a reset.
    static var pairingService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")
    static var connectivityCharacteristic = CBUUID(string: "00000001-328E-0FBB-C642-1AA6699BDADA")
    static var pairingTriggerCharacteristic = CBUUID(string: "00000002-328E-0FBB-C642-1AA6699BDADA")
    static var connectionParametersCharacteristic = CBUUID(string: "00000005-328E-0FBB-C642-1AA6699BDADA")
    static var ppogNotifyCharacteristic = CBUUID(string: "40000001-328E-0FBB-C642-1AA6699BDADA")
    static var ppogWriteCharacteristic = CBUUID(string: "40000003-328E-0FBB-C642-1AA6699BDADA")
    static var batteryService = CBUUID(string: "180F")
    static var batteryLevelCharacteristic = CBUUID(string: "2A19")

    var centralManager: CBCentralManager!
    var discoveredPeripherals: [WatchID: CBPeripheral] = [:]
    var scanResults: [WatchID: DiscoveredWatch] = [:]
    var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredWatch], any Error>?
    var connectionContinuation: CheckedContinuation<ConnectedWatch, any Error>?
    /// Whoever asked for the connect that is in flight, for the phases between
    /// the link coming up and the watch answering. Nil once it has answered.
    var handshakePhaseReporter: (@MainActor (WatchHandshakePhase) -> Void)?
    /// Set while a session started over on a live link waits for the watch to
    /// answer its version request.
    ///
    /// That answer is almost always word for word the one before, and the app
    /// has to hear it anyway: it is the only thing that says the transport is
    /// usable again and the work interrupted by the restart needs re-doing.
    var isRestartingSession = false
    /// Deadline for a session started over on a live link. Without it a watch
    /// that asks for a reset and then says nothing leaves the link up with no
    /// transport on it, and nothing notices until the health check fails a
    /// minute later.
    var sessionRestartTimeoutTask: Task<Void, Never>?
    var pendingDevice: DiscoveredWatch?
    var activeWriteCharacteristic: CBCharacteristic?
    var activeBatteryCharacteristic: CBCharacteristic?
    var activePairingTriggerCharacteristic: CBCharacteristic?
    var ppogNotifyCharacteristicToSubscribe: CBCharacteristic?
    var setup = LinkSetup()
    /// Watches whose link was asked for with the notification requirement and
    /// did not come up. See `connectOptions(for:)`.
    var refusedNotificationAccess: Set<UUID> = []
    /// Whether the attempt in flight carried that requirement, so a failure can
    /// be told apart from one that had nothing to do with it.
    var requiredNotificationAccess = false
    var pairingTimeoutTask: Task<Void, Never>?
    var subscriptionWatchdog: Task<Void, Never>?
    var hasRepublishedForThisLink = false
    var connectedPeripheral: CBPeripheral?
    var connectedWatch: ConnectedWatch?
    private var latestBatteryLevel: Int?
    var ppogSession: PPoGSession?
    var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    var eventContinuation: AsyncStream<WatchClientEvent>.Continuation?
    private var pendingGattWrites: Deque<Data> = []
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var healthCheckTimeoutTask: Task<Void, Never>?
    let reconnects = ReconnectPolicy()
    private var isAwaitingHealthCheckReply = false
    var activeTransferSession: PutBytesTransferSession?
    var completedTransferCookie: UInt32?
    let firmwareReply = PendingReply<Void>()
    var waitingForFirmwareStart = false
    var isInstallingFirmware = false
    var pendingInstallCookie: UInt32?
    let transferReply = PendingReply<Void>()
    var nextBlobDBToken: UInt16 = 1
    var pendingBlobDBToken: UInt16?
    var acceptedBlobDBStatuses: [BlobDBStatus] = []
    let blobDBReply = PendingReply<Void>()
    let blobDBQueue = BlobDBQueue()
    let appReorderReply = PendingReply<Void>()
    private let appMessages = AppMessageQueue()
    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()
    let screenshot = WatchPull<ScreenshotCollector>(timeout: .seconds(30))
    let logDump = WatchPull<LogDumpCollector>(timeout: .seconds(30))
    var nextLogDumpCookie: UInt32 = 1
    let fileBytes = WatchPull<GetBytesCollector>(timeout: .seconds(60))
    var nextGetBytesTransactionID: UInt8 = 1

    let clientTag: String

    private let restoreIdentifier: String

    public init(restoreIdentifier: String = "dev.pebble.central") {
        self.restoreIdentifier = restoreIdentifier
        clientTag = String(restoreIdentifier.split(separator: ".").last ?? "central")
        super.init()
        appMessages.send = { [weak self] data in
            guard let self else { throw WatchConnectionError.disconnected }
            try sendFrame(AppMessageCodec.pushFrame(data), to: try linkedPeripheral())
        }
        observeSystemTimeChanges()
    }

    /// Makes the central and publishes the phone's own service.
    ///
    /// Not done in `init`: making either manager is what raises the system's
    /// Bluetooth dialog, and this class is made while the app is starting, which
    /// on a fresh install means being asked for permission before having asked
    /// for a watch. Whoever wants the radio calls this, and everything that
    /// needs it calls it on the way in.
    public func startBluetooth() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        )
        // Watches inspect the phone's GATT database right after connecting, so
        // the phone-hosted protocol service has to exist before that.
        PebbleGattServer.shared.start()
    }

    /// The watch to write to, once there is a session to write into. A connected
    /// peripheral is not enough: the transport is not open until the PPoG
    /// handshake finishes, and anything sent before that is lost rather than
    /// queued.
    func linkedPeripheral() throws -> CBPeripheral {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw WatchConnectionError.disconnected
        }
        return peripheral
    }

    /// A locally cancelled link arrives back as a disconnect with no error,
    /// which is indistinguishable from the watch going away.
    func cancelLink(_ peripheral: CBPeripheral, reason: String) {
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] dropping link: \(reason)"
            )
        }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    public func scan() async throws -> [DiscoveredWatch] {
        try await waitForBluetooth()

        guard scanContinuation == nil else {
            throw WatchConnectionError.scanAlreadyInProgress
        }

        scanResults.removeAll()
        discoveredPeripherals.removeAll()

        return try await withCheckedThrowingContinuation { continuation in
            scanContinuation = continuation
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )

            scanTimeoutTask?.cancel()
            scanTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else {
                    return
                }
                self?.finishScan()
            }
        }
    }

    public func retrieveKnownWatches(_ hints: [DiscoveredWatch]) async throws -> [DiscoveredWatch] {
        try await waitForBluetooth()

        // A bonded Pebble stays connected at the system level and stops
        // advertising, so it has to be looked up instead of scanned for.
        let hintsByID = Dictionary(hints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var peripherals = centralManager.retrieveConnectedPeripherals(withServices: [Self.ppogService])
        // A watch this transport found is named by its CoreBluetooth
        // identifier, so a hint from another transport — the emulator's
        // "qemu-emery" — has nothing to look up and drops out here.
        peripherals += centralManager.retrievePeripherals(
            withIdentifiers: hints.compactMap { UUID(uuidString: $0.id.rawValue) }
        )

        var retrieved: [DiscoveredWatch] = []
        for peripheral in peripherals {
            let id = peripheral.watchID
            guard let hint = hintsByID[id], !retrieved.contains(where: { $0.id == id }) else {
                continue
            }
            discoveredPeripherals[id] = peripheral
            let device = DiscoveredWatch(
                id: id,
                name: peripheral.name ?? hint.name,
                model: hint.model,
                signalStrength: hint.signalStrength
            )
            scanResults[id] = device
            retrieved.append(device)
        }
        return retrieved
    }

    public func connect(
        to device: DiscoveredWatch,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        try await waitForBluetooth()

        guard connectionContinuation == nil else {
            throw WatchConnectionError.connectionAlreadyInProgress
        }
        // Held for the length of the handshake, and cleared with the
        // continuation: a phase reported against a connect that has already
        // finished would move the app off `connected`.
        handshakePhaseReporter = reportingPhase
        if let connectedWatch, connectedWatch.id == device.id {
            return connectedWatch
        }
        reconnects.stop()
        if let previousPeripheral = connectedPeripheral {
            reconnects.expectDisconnect(of: previousPeripheral.watchID)
            cancelLink(previousPeripheral, reason: "a manual connect superseded it")
            clearTransportState()
        }
        if discoveredPeripherals[device.id] == nil {
            _ = try await retrieveKnownWatches([device])
        }
        guard let peripheral = discoveredPeripherals[device.id] else {
            throw WatchConnectionError.watchNotFound
        }

        centralManager.stopScan()
        pendingDevice = DiscoveredWatch(
            id: device.id,
            name: peripheral.name ?? device.name,
            model: device.model,
            signalStrength: device.signalStrength
        )
        peripheral.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            centralManager.connect(peripheral, options: connectOptions(for: peripheral))

            // A reconnect in flight has its own deadline armed here, and it
            // tears the link down when it expires. Left running it would
            // outlive this connect and drop the healthy link it produced.
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else {
                    return
                }
                self?.failConnection(.connectionTimedOut)
            }
        }
    }

    public func disconnect(from device: ConnectedWatch) async {
        // Stop the reconnection machinery first: a scheduled retry captured
        // its peripheral by value and would otherwise undo this disconnect.
        if reconnects.isFollowing(device.id) {
            reconnects.stop()
        }
        guard let peripheral = discoveredPeripherals[device.id]
            ?? (connectedPeripheral?.watchID == device.id ? connectedPeripheral : nil) else {
            return
        }
        if peripheral.state != .disconnected {
            // Only expect a disconnect callback when a link actually exists;
            // a stale marker would suppress reconnection after a later drop.
            reconnects.expectDisconnect(of: device.id)
        }
        stopHealthChecks()
        cancelLink(peripheral, reason: "the app asked to disconnect")
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        let peripheral = try linkedPeripheral()
        // `sendFrame` records it, and so does every path that reaches the watch
        // without coming through here.
        try sendFrame(frame, to: peripheral)
    }

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in
            frameContinuation?.finish()
            frameContinuation = continuation
        }
    }

    public func events() -> AsyncStream<WatchClientEvent> {
        AsyncStream { continuation in
            eventContinuation?.finish()
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {
        let peripheral = try linkedPeripheral()
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        let peripheral = try linkedPeripheral()
        try sendFrame(AppFetchCodec.responseFrame(status: status), to: peripheral)
    }

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        _ = try linkedPeripheral()
        try await appMessages.enqueue(applicationID: applicationID, tuples: tuples)
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        let peripheral = try linkedPeripheral()
        try sendFrame(
            AppMessageCodec.resultFrame(transactionID: transactionID, acknowledged: acknowledged),
            to: peripheral
        )
    }

    public func launchApplication(id: UUID) async throws {
        try await send(AppRunStateCodec.startFrame(applicationID: id))
    }

    public func refreshWatchInformation() async throws {
        guard let peripheral = connectedPeripheral else { throw WatchConnectionError.disconnected }
        try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
    }

    public func sendImage(
        token: UInt8,
        kindValue: UInt8,
        image: EncodedImage?
    ) async throws {
        // The chunks are one transfer as far as the watch is concerned: another
        // response arriving between them abandons it, so they go out together.
        for frame in ImagingCodec.responseFrames(token: token, kindValue: kindValue, image: image) {
            try await send(frame)
        }
    }

    public func declineImageKind(token: UInt8, kindValue: UInt8) async throws {
        try await send(ImagingCodec.unsupportedFrame(token: token, kindValue: kindValue))
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    private func waitForBluetooth() async throws {
        startBluetooth()
        switch centralManager.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw WatchConnectionError.permissionDenied
        case .unsupported:
            throw WatchConnectionError.bluetoothUnsupported
        case .poweredOff, .resetting:
            throw WatchConnectionError.bluetoothUnavailable
        case .unknown:
            try await withCheckedThrowingContinuation { continuation in
                bluetoothWaiters.append(continuation)
            }
        @unknown default:
            throw WatchConnectionError.bluetoothUnavailable
        }
    }

    private func finishScan() {
        centralManager.stopScan()
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil

        let devices = scanResults.values.sorted { lhs, rhs in
            lhs.signalStrength > rhs.signalStrength
        }
        scanContinuation?.resume(returning: devices)
        scanContinuation = nil
    }

    func failScan(_ error: WatchConnectionError) {
        centralManager.stopScan()
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        scanContinuation?.resume(throwing: error)
        scanContinuation = nil
    }

    private func finishConnection(
        peripheral: CBPeripheral,
        information: WatchVersionInformation
    ) {
        guard let device = pendingDevice else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let connectedWatch = ConnectedWatch(
            id: peripheral.watchID,
            name: device.name,
            model: WatchModel(hardwarePlatform: information.hardwarePlatform) ?? device.model,
            firmwareVersion: information.firmwareVersion,
            batteryLevel: latestBatteryLevel,
            serialNumber: information.serialNumber,
            isRunningRecoveryFirmware: information.isRunningRecoveryFirmware,
            runningFirmwareSlot: information.runningFirmwareSlot,
            board: information.board,
            languageLocale: information.languageLocale,
            languageVersion: information.languageVersion,
            capabilities: information.capabilities
        )
        self.connectedWatch = connectedWatch
        let initialConnectionContinuation = connectionContinuation
        initialConnectionContinuation?.resume(returning: connectedWatch)
        connectionContinuation = nil
        handshakePhaseReporter = nil
        pendingDevice = nil
        connectedPeripheral = peripheral
        reconnects.follow(device)
        if initialConnectionContinuation == nil {
            eventContinuation?.yield(.watchUpdated(connectedWatch))
        }
        startHealthChecks(on: peripheral)
        appMessages.startNextIfPossible()
    }

    /// `step` names what the link was doing. Eleven places report the same
    /// `protocolNegotiationFailed`, and a log that only carries the error says
    /// nothing about which of them a watch stopped at.
    func abortLink(
        _ peripheral: CBPeripheral,
        error: WatchConnectionError,
        step: String
    ) {
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                .error,
                category: "pairing",
                message: "[\(tag)] giving up while \(step)"
            )
        }
        if connectionContinuation != nil {
            failConnection(error)
            return
        }
        cancelLink(peripheral, reason: "transport failure: \(error.logDescription)")
    }

    func failConnection(_ error: WatchConnectionError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        setup.reset()
        ppogNotifyCharacteristicToSubscribe = nil
        activePairingTriggerCharacteristic = nil
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
        handshakePhaseReporter = nil
        // Withdraw the pending connect request: CoreBluetooth otherwise keeps
        // it queued forever and a late didConnect would create a session the
        // app no longer expects.
        if let pending = pendingDevice,
           let peripheral = discoveredPeripherals[pending.id] {
            cancelLink(peripheral, reason: "the connect attempt failed: \(error.logDescription)")
        }
        pendingDevice = nil
        activeWriteCharacteristic = nil
        activeBatteryCharacteristic = nil
        connectedPeripheral = nil
        connectedWatch = nil
        latestBatteryLevel = nil
        ppogSession = nil
        pendingGattWrites.removeAll()
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
        completedTransferCookie = nil
        stopHealthChecks()
        failWorkInFlight(error)
    }

    func model(from advertisementData: [String: Any]) -> WatchModel? {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return PebbleAdvertisement.model(
            advertisesPebbleService: serviceUUIDs.contains(Self.ppogService)
                || serviceUUIDs.contains(Self.pairingService),
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: [UInt8](
                advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
            )
        )
    }

    func write(_ packet: PPoGPacket, to peripheral: CBPeripheral) throws {
        recordPPoGPacket(packet, direction: "out")
        let bytes = try packet.encoded(for: .one)
        if setup.transport == .forward {
            guard PebbleGattServer.shared.send(bytes, to: peripheral.identifier.uuidString) else {
                throw WatchConnectionError.protocolNegotiationFailed
            }
            return
        }
        guard let characteristic = activeWriteCharacteristic else {
            throw WatchConnectionError.protocolNegotiationFailed
        }
        pendingGattWrites.append(Data(bytes))
        flushWrites(to: peripheral, characteristic: characteristic)
    }

    func flushWrites(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        while peripheral.canSendWriteWithoutResponse,
              !pendingGattWrites.isEmpty {
            let value = pendingGattWrites.removeFirst()
            peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
        }
    }

    func handle(
        _ actions: [PPoGSessionAction],
        peripheral: CBPeripheral
    ) throws {
        // The watch coalesces frames for unrelated endpoints into one delivery,
        // and the session queues the acknowledgement behind them, so giving up
        // on the first unusable frame loses the reply a caller is waiting for
        // and makes the watch retransmit the window.
        var firstFailure: (any Error)?
        for action in actions {
            switch action {
            case .send(let packet):
                try write(packet, to: peripheral)
            case .deliver(let bytes):
                let batch = frameDecoder.append(bytes)
                if firstFailure == nil, let failure = batch.failure {
                    firstFailure = failure
                }
                for frame in batch.frames {
                    do {
                        try process(frame, peripheral: peripheral)
                    } catch {
                        if firstFailure == nil {
                            firstFailure = error
                        }
                    }
                    frameContinuation?.yield(frame)
                }
            case .resetRequired:
                throw WatchConnectionError.protocolNegotiationFailed
            }
        }
        if let firstFailure {
            throw firstFailure
        }
    }

    func sendFrame(
        _ frame: PebbleProtocolFrame,
        to peripheral: CBPeripheral
    ) throws {
        guard var session = ppogSession else {
            throw WatchConnectionError.disconnected
        }

        Task { await PebbleDiagnostics.shared.recordFrame(direction: "out", frame: frame) }
        let bytes = try frame.encoded()
        let maximumPacketSize = setup.transport == .forward
            ? PebbleGattServer.shared.maximumPacketSize(centralID: peripheral.identifier.uuidString)
            : peripheral.maximumWriteValueLength(for: .withoutResponse)
        let actions = try session.enqueue(bytes, maximumPacketSize: maximumPacketSize)
        ppogSession = session
        try handle(actions, peripheral: peripheral)
        updateAcknowledgementTimeout(for: peripheral)
    }

    private func process(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        Task { await PebbleDiagnostics.shared.recordFrame(direction: "in", frame: frame) }
        if try answer(frame, peripheral: peripheral) { return }
        // A frame the app takes off `frames()` is answered, just not here, and
        // the audio endpoint alone sends fifty a second.
        guard CompanionFrame(endpoint: frame.endpoint) == nil else { return }
        Task { [frame, tag = clientTag] in
            await PebbleDiagnostics.shared.recordUnansweredFrame(frame, tag: tag)
        }
    }

    /// Whether anything in the app was waiting for this frame.
    ///
    /// One case an endpoint, so that what a new one does cannot depend on where
    /// in a list it was written: the two endpoints that answer more than one
    /// thing choose between them themselves. An answer with nobody waiting is
    /// not an error — a reply to a request already given up on, or an endpoint
    /// this app does not implement, is worth a line in the log and no more.
    private func answer(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        switch frame.endpoint {
        case PebbleProtocolFrame.metaEndpoint:
            // "I do not know that endpoint" is still an answer, and a link the
            // watch is holding up perfectly well should not be dropped for it.
            guard frame.rejectedEndpoint == WatchVersionCodec.endpoint else { return false }
            clearPendingHealthCheck()

        case PingPongCodec.endpoint:
            try processPingPong(frame, peripheral: peripheral)

        case PhoneVersionCodec.endpoint:
            guard PhoneVersionCodec.isRequest(frame) else { return false }
            #if os(macOS)
            let operatingSystem = PhoneOperatingSystem.macOS
            #else
            let operatingSystem = PhoneOperatingSystem.iOS
            #endif
            try sendFrame(
                PhoneVersionCodec.responseFrame(operatingSystem: operatingSystem),
                to: peripheral
            )

        case WatchVersionCodec.endpoint:
            return try answerWatchVersion(frame, peripheral: peripheral)

        case AppFetchCodec.endpoint:
            eventContinuation?.yield(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))

        case HealthSyncCodec.endpoint:
            eventContinuation?.yield(.healthSyncCompleted(try HealthSyncResponseCodec.decode(frame)))

        case HealthDataLoggingCodec.endpoint:
            let result = try healthDataLoggingProcessor.process(frame)
            if let response = result.response { try sendFrame(response, to: peripheral) }
            if !result.samples.isEmpty { eventContinuation?.yield(.healthSamplesReceived(result.samples)) }

        case TimelineActionCodec.endpoint:
            let invocation = try TimelineActionCodec.decode(frame)
            eventContinuation?.yield(.timelineActionInvoked(invocation))
            try sendFrame(
                TimelineActionCodec.responseFrame(itemID: invocation.itemID, succeeded: true),
                to: peripheral
            )

        case AppRunStateCodec.endpoint:
            eventContinuation?.yield(.appRunStateChanged(try AppRunStateCodec.decode(frame)))

        case ScreenshotCodec.endpoint:
            return screenshot.take(frame)

        case LogDumpCodec.endpoint:
            return logDump.take(frame)

        case GetBytesCodec.endpoint:
            return fileBytes.take(frame)

        case AppLogCodec.endpoint:
            let (applicationID, line) = try AppLogCodec.decode(frame)
            eventContinuation?.yield(.applicationLogReceived(applicationID: applicationID, line: line))

        case ImagingCodec.endpoint:
            eventContinuation?.yield(.imageRequested(try ImagingCodec.decode(frame)))

        case AppMessageCodec.endpoint:
            processAppMessage(frame)

        case AppReorderCodec.endpoint:
            guard appReorderReply.isWaiting else { return false }
            processAppReorderResponse(frame)

        case PutBytesCodec.endpoint:
            return try answerPutBytes(frame, peripheral: peripheral)

        case SystemMessageCodec.endpoint:
            guard waitingForFirmwareStart else { return false }
            waitingForFirmwareStart = false
            try SystemMessageCodec.decodeFirmwareUpdateStartResponse(frame)
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: SystemMessageCodecError.updateRejected)

        case BlobDBCodec.endpoint:
            guard pendingBlobDBToken != nil else { return false }
            processBlobDBResponse(frame)

        default:
            return false
        }
        return true
    }

    private func answerWatchVersion(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        // The watch changes what it reports when a language pack is installed,
        // which is how the app finds out.
        if pendingDevice == nil, let device = connectedWatch {
            clearPendingHealthCheck()
            let information = try WatchVersionCodec.decode(frame)
            var updated = device
            updated.firmwareVersion = information.firmwareVersion
            updated.serialNumber = information.serialNumber
            updated.isRunningRecoveryFirmware = information.isRunningRecoveryFirmware
            updated.runningFirmwareSlot = information.runningFirmwareSlot
            updated.board = information.board
            updated.languageLocale = information.languageLocale
            updated.languageVersion = information.languageVersion
            updated.capabilities = information.capabilities
            connectedWatch = updated
            // The health check asks for this once a minute and the answer is
            // almost always the same one; announcing it anyway had the app
            // rewriting its watch library every minute. A session started over
            // is the exception: the app is waiting to hear that the transport
            // works before it re-sends anything.
            if updated != device || isRestartingSession {
                eventContinuation?.yield(.watchUpdated(updated))
            }
            isRestartingSession = false
            return true
        }

        guard pendingDevice != nil else { return false }
        let information = try WatchVersionCodec.decode(frame)
        Task { [
            tag = clientTag,
            version = information.firmwareVersion,
            board = information.board?.rawValue ?? "platform \(information.hardwarePlatform)",
            recovery = information.isRunningRecoveryFirmware
        ] in
            await PebbleDiagnostics.shared.record(
                recovery ? .error : .info,
                category: "connection",
                message: "[\(tag)] firmware \(version) on \(board)"
                    + (recovery ? " (recovery firmware: only a firmware install will work)" : "")
            )
        }
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
        finishConnection(peripheral: peripheral, information: information)
        return true
    }

    private func processAppMessage(_ frame: PebbleProtocolFrame) {
        do {
            switch try AppMessageCodec.decode(frame) {
            case .push(let message):
                eventContinuation?.yield(.appMessageReceived(message))
            case .acknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive()
            case .negativeAcknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive(throwing: AppMessageClientError.negativeAcknowledgement)
            }
        } catch {
        }
    }

    private func processPingPong(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        switch try PingPongCodec.decode(frame) {
        case .ping(let cookie):
            // The watch pings the phone about once an hour and drops a link it
            // gets no pong on. Nothing is ever sent the other way: the firmware
            // answers a ping from the phone by pushing a "Ping" dialog in front
            // of whatever the reader was doing — `prv_push_window` in
            // `services/ping/service.c`, unconditionally.
            try sendFrame(PingPongCodec.frame(for: .pong(cookie: cookie)), to: peripheral)
        case .pong:
            break
        }
    }

    private func startHealthChecks(on peripheral: CBPeripheral) {
        stopHealthChecks()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else {
                    return
                }
                self?.sendHealthCheck(on: peripheral)
            }
        }
    }

    /// Whether the link still carries the protocol, asked in a way the watch
    /// does not show: a version request is answered by `prv_send_watch_versions`
    /// and nothing else.
    private func sendHealthCheck(on peripheral: CBPeripheral) {
        guard !isAwaitingHealthCheckReply else {
            return
        }
        // A transfer can keep the watch busy for longer than the pong deadline,
        // and an install has gaps between transfers while the watch commits.
        guard activeTransferSession == nil, !isInstallingFirmware else {
            return
        }
        // A watch being recovered cannot afford a dropped link, and its own
        // timeouts cover the transfer.
        guard connectedWatch?.isRunningRecoveryFirmware != true else {
            return
        }
        do {
            try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
            isAwaitingHealthCheckReply = true
            healthCheckTimeoutTask?.cancel()
            healthCheckTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self?.isAwaitingHealthCheckReply == true else {
                    return
                }
                self?.cancelLink(peripheral, reason: "no answer to the health check within 15s")
            }
        } catch {
            cancelLink(peripheral, reason: "could not send the health check")
        }
    }

    private func clearPendingHealthCheck() {
        isAwaitingHealthCheckReply = false
        healthCheckTimeoutTask?.cancel()
        healthCheckTimeoutTask = nil
    }

    private func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        clearPendingHealthCheck()
    }

    /// Gives up the protocol session while keeping the link that carries it.
    ///
    /// The watch sends a reset mid-session when its acknowledgement timeouts have
    /// run out. What it is asking for is the transport reopened, not the link
    /// dropped — and dropping the link cost a whole reconnect, the bond check and
    /// the several seconds of handshake with it. The work in flight goes either
    /// way, because its tokens belonged to the session that has just ended, and
    /// the app is told the same way a reconnect tells it so that it re-sends
    /// what it has to.
    func abandonSession(on peripheral: CBPeripheral, because reason: String) {
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                .warning,
                category: "ppog",
                message: "[\(tag)] starting the session over: \(reason)"
            )
        }
        ppogSession = nil
        frameDecoder = PebbleProtocolFrameDecoder()
        // The next handshake owes a ResetComplete again.
        setup.forgetResetComplete()
        pendingGattWrites.removeAll()
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        // A reply to the check sent over the session that has gone is not coming;
        // the periodic check itself keeps running and is what notices if the
        // restart quietly fails.
        clearPendingHealthCheck()
        failWorkInFlight(.disconnected)
        // Deliberately left alone, unlike `clearTransportState`: the bond, the
        // watch, the health-logging session and the records the watch holds all
        // outlive a transport that was reopened.
        isRestartingSession = true
        sessionRestartTimeoutTask?.cancel()
        sessionRestartTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.ppogSession == nil else { return }
            self?.cancelLink(peripheral, reason: "the session was never started over")
        }
        if let device = connectedWatch {
            eventContinuation?.yield(.reconnecting(watchID: device.id))
        }
    }

    func clearTransportState() {
        isRestartingSession = false
        sessionRestartTimeoutTask?.cancel()
        sessionRestartTimeoutTask = nil
        activeWriteCharacteristic = nil
        activeBatteryCharacteristic = nil
        activePairingTriggerCharacteristic = nil
        ppogNotifyCharacteristicToSubscribe = nil
        setup.reset()
        subscriptionWatchdog?.cancel()
        subscriptionWatchdog = nil
        hasRepublishedForThisLink = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        connectedPeripheral = nil
        connectedWatch = nil
        latestBatteryLevel = nil
        ppogSession = nil
        frameDecoder = PebbleProtocolFrameDecoder()
        pendingGattWrites.removeAll()
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        // A session id only means something inside the session that opened it.
        // After a reconnect the watch reuses low ids freely, and reading new
        // records with an old session's tag and item size turns them into
        // nonsense instead of a rejection.
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
        completedTransferCookie = nil
        stopHealthChecks()
        failWorkInFlight(.disconnected)
    }

    /// Fails everything the watch was in the middle of answering.
    ///
    /// A BlobDB token, a transfer cookie, a pull, an app reorder and a firmware
    /// control exchange all mean something only inside the session that started
    /// them. When it ends the watch will never answer any of them, and saying so
    /// now beats each one's own deadline blaming itself ten seconds later.
    func failWorkInFlight(_ error: WatchConnectionError) {
        failTransfer(error)
        failBlobDBOperation(error)
        blobDBQueue.failAll(error)
        failPulls(error)
        failAppReorder(error)
        finishFirmwareControl(throwing: error)
        // `AppModel` keeps its own list of undelivered messages and flushes it
        // on the next connection, so a copy held here would be sent twice.
        appMessages.failAll(error)
    }

    /// Asks iOS for the notification-sharing decision as part of connecting.
    ///
    /// Without this the question is only raised when the watch itself gets round
    /// to asking for ANCS, which is whenever iOS chooses — in practice long
    /// after the reader has left the app, which is where the alert was turning
    /// up. Requiring it here puts the alert on the connect the reader started.
    ///
    /// It is dropped for a watch that has already failed to connect with it,
    /// because with this set a refusal is a failed link: a watch that connects
    /// without notifications is worth more than one that will not connect.
    func connectOptions(for peripheral: CBPeripheral) -> [String: Any]? {
        #if os(iOS)
        guard !refusedNotificationAccess.contains(peripheral.identifier) else {
            requiredNotificationAccess = false
            return nil
        }
        requiredNotificationAccess = true
        return [CBConnectPeripheralOptionRequiresANCS: true]
        #else
        requiredNotificationAccess = false
        return nil
        #endif
    }

    /// Retries without the notification requirement, once per watch.
    ///
    /// Returns whether this attempt is the one being retried, in which case the
    /// caller has nothing left to report: the link is being asked for again.
    func retryWithoutNotificationAccess(_ peripheral: CBPeripheral) -> Bool {
        guard requiredNotificationAccess,
              !refusedNotificationAccess.contains(peripheral.identifier) else {
            return false
        }
        refusedNotificationAccess.insert(peripheral.identifier)
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                .warning,
                category: "pairing",
                message: "[\(tag)] the link was refused with notification sharing required; asking again without it"
            )
        }
        centralManager.connect(peripheral, options: connectOptions(for: peripheral))
        return true
    }

    func reconnect(to device: DiscoveredWatch, using peripheral: CBPeripheral) {
        reconnects.cancelSchedule()
        guard centralManager.state == .poweredOn else {
            eventContinuation?.yield(.reconnecting(watchID: device.id))
            scheduleReconnect(to: device, using: peripheral)
            return
        }
        pendingDevice = device
        reconnects.beginAutomaticAttempt()
        peripheral.delegate = self
        eventContinuation?.yield(.reconnecting(watchID: device.id))
        centralManager.connect(peripheral, options: connectOptions(for: peripheral))

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else {
                return
            }
            self?.cancelLink(peripheral, reason: "the reconnect handshake stalled for 30s")
        }
    }

    /// Stops chasing a watch whose links keep dying in the handshake, and says
    /// so: the reader was told "Reconnecting…" for as long as they watched.
    func giveUpReconnecting(to device: DiscoveredWatch) {
        let attempts = reconnects.failedHandshakes
        reconnects.stop()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pendingDevice = nil
        Task { [tag = clientTag, name = device.name] in
            await PebbleDiagnostics.shared.record(
                .error,
                category: "connection",
                message: "[\(tag)] giving up on \(name):"
                    + " \(attempts) links came up and none finished the handshake"
            )
        }
        eventContinuation?.yield(.disconnected(.handshakeKeptFailing))
    }

    func scheduleReconnect(to device: DiscoveredWatch, using peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        reconnects.schedule { [weak self] in
            self?.reconnect(to: device, using: peripheral)
        }
    }

    func resumeReconnectAfterPowerOn() {
        guard let device = reconnects.watch,
              connectedWatch == nil,
              connectionContinuation == nil else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The pre-power-cycle CBPeripheral may be invalid; look it up again.
            _ = try? await self.retrieveKnownWatches([device])
            guard self.reconnects.watch?.id == device.id,
                  self.connectedWatch == nil,
                  self.connectionContinuation == nil,
                  let peripheral = self.discoveredPeripherals[device.id] else {
                return
            }
            self.reconnect(to: device, using: peripheral)
        }
    }

    func updateBatteryLevel(from bytes: [UInt8]) {
        guard let batteryLevel = BatteryLevelCodec.decode(bytes) else {
            return
        }

        latestBatteryLevel = batteryLevel
        guard var device = connectedWatch else {
            return
        }
        device.batteryLevel = batteryLevel
        connectedWatch = device
        eventContinuation?.yield(.watchUpdated(device))
    }

    private func observeSystemTimeChanges() {
        let notificationCenter = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
        ]

        timeChangeObservers.observers = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    try? await self?.synchronizeTime()
                }
            }
        }
    }

    func updateAcknowledgementTimeout(for peripheral: CBPeripheral) {
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil

        guard ppogSession?.hasPendingAcknowledgements == true else {
            return
        }

        acknowledgementTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else {
                return
            }
            self?.retryUnacknowledgedPackets(on: peripheral)
        }
    }

    private func retryUnacknowledgedPackets(on peripheral: CBPeripheral) {
        guard var session = ppogSession else {
            return
        }

        do {
            let actions = try session.handleAcknowledgementTimeout()
            ppogSession = session
            try handle(actions, peripheral: peripheral)
            updateAcknowledgementTimeout(for: peripheral)
        } catch {
            abortLink(peripheral, error: .connectionTimedOut, step: "resending unacknowledged packets")
        }
    }
}

public enum PutBytesClientError: Error, Equatable, Sendable {
    case transferAlreadyInProgress
    case firmwareUpdateAlreadyInProgress
}
