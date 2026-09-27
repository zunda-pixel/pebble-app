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
/// and the health check that decides a link has died. What the watch is
/// *asked* for, and how its answers are read, is `WatchSession`'s, which the
/// emulator's client shares; `+Records` hands it on. The two delegate
/// conformances are in `+Central` and `+Peripheral`.
///
/// Swift has no access level for "this type across its files", so everything
/// those files touch is `internal` rather than `private`. `internal` reaches no
/// further than this module.
@MainActor
public final class CoreBluetoothWatchClient: NSObject, WatchClient {
    static let ppogService = CBUUID(string: "40000000-328E-0FBB-C642-1AA6699BDADA")
    /// Advertised by watches that are not bonded yet, including after a reset.
    static let pairingService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")
    static let connectivityCharacteristic = CBUUID(string: "00000001-328E-0FBB-C642-1AA6699BDADA")
    static let pairingTriggerCharacteristic = CBUUID(string: "00000002-328E-0FBB-C642-1AA6699BDADA")
    static let connectionParametersCharacteristic = CBUUID(string: "00000005-328E-0FBB-C642-1AA6699BDADA")
    static let ppogNotifyCharacteristic = CBUUID(string: "40000001-328E-0FBB-C642-1AA6699BDADA")
    static let ppogWriteCharacteristic = CBUUID(string: "40000003-328E-0FBB-C642-1AA6699BDADA")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevelCharacteristic = CBUUID(string: "2A19")

    var centralManager: CBCentralManager!
    var discoveredPeripherals: [WatchID: CBPeripheral] = [:]
    var scanResults: [WatchID: DiscoveredWatch] = [:]
    var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredWatch], any Error>?
    var connectionContinuation: CheckedContinuation<ConnectedWatch, any Error>?
    /// Whoever asked for the connect that is in flight, for the phases between
    /// the link coming up and the watch answering. Nil once it has answered.
    var handshakePhaseReporter: (@MainActor (WatchHandshakePhase) -> Void)?
    var pendingWatch: WatchConnectionTarget?
    /// Everything that belongs to the link up now, reset in one place when it
    /// goes. See `endLink()`.
    var link = LinkState()
    /// Watches whose link was asked for with the notification requirement and
    /// did not come up. See `connectOptions(for:)`.
    var refusedNotificationAccess: Set<UUID> = []
    /// Whether the attempt in flight carried that requirement, so a failure can
    /// be told apart from one that had nothing to do with it.
    var requiredNotificationAccess = false
    var connectedPeripheral: CBPeripheral?
    var connectedWatch: ConnectedWatch?
    var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    var eventContinuation: AsyncStream<WatchClientEvent>.Continuation?
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    var connectionTimeoutTask: Task<Void, Never>?
    var healthCheckTask: Task<Void, Never>?
    var healthCheckTimeoutTask: Task<Void, Never>?
    let reconnects = ReconnectPolicy()
    var isAwaitingHealthCheckReply = false
    /// Lazy so that it can hold on to this client weakly: an initializer
    /// cannot hand out `self` before every property is set.
    lazy var session = WatchSession(
        tag: clientTag,
        operatingSystem: Self.operatingSystem,
        isLinked: { [weak self] in (try? self?.linkedPeripheral()) != nil },
        send: { [weak self] frame in
            guard let self else { throw WatchConnectionError.disconnected }
            try self.sendFrame(frame, to: try self.linkedPeripheral())
        },
        report: { [weak self] event in self?.eventContinuation?.yield(event) }
    )

    #if os(macOS)
    private static let operatingSystem = PhoneOperatingSystem.macOS
    #else
    private static let operatingSystem = PhoneOperatingSystem.iOS
    #endif

    let clientTag: String

    private let restoreIdentifier: String

    public init(restoreIdentifier: String = "dev.pebble.central") {
        self.restoreIdentifier = restoreIdentifier
        clientTag = String(restoreIdentifier.split(separator: ".").last ?? "central")
        super.init()
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
        if Self.servesTheProtocolItself {
            GATTServer.shared.start()
        }
    }

    /// The watch to write to, once there is a session to write into. A connected
    /// peripheral is not enough: the transport is not open until the PPoG
    /// handshake finishes, and anything sent before that is lost rather than
    /// queued.
    func linkedPeripheral() throws -> CBPeripheral {
        guard let peripheral = connectedPeripheral, link.ppogSession != nil else {
            throw WatchConnectionError.disconnected
        }
        return peripheral
    }

    /// A locally cancelled link arrives back as a disconnect with no error,
    /// which is indistinguishable from the watch going away.
    func cancelLink(_ peripheral: CBPeripheral, reason: String) {
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
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

    public func retrieveKnownWatches(_ hints: [WatchConnectionTarget]) async throws -> [DiscoveredWatch] {
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
            // A looked-up watch was not heard: no advertisement, so no RSSI,
            // and the model is whatever the hint remembered — possibly
            // nothing. Both say so as nil rather than as invented numbers.
            let watch = DiscoveredWatch(
                id: id,
                name: peripheral.name ?? hint.name,
                model: hint.model,
                signalStrength: nil
            )
            scanResults[id] = watch
            retrieved.append(watch)
        }
        return retrieved
    }

    public func connect(
        to watch: WatchConnectionTarget,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        try await waitForBluetooth()

        guard connectionContinuation == nil else {
            throw WatchConnectionError.connectionAlreadyInProgress
        }
        if let connectedWatch, connectedWatch.id == watch.id {
            return connectedWatch
        }
        reconnects.stop()
        if let previousPeripheral = connectedPeripheral {
            reconnects.expectDisconnect(of: previousPeripheral.watchID)
            cancelLink(previousPeripheral, reason: "a manual connect superseded it")
            clearTransportState()
        }
        if discoveredPeripherals[watch.id] == nil {
            _ = try await retrieveKnownWatches([watch])
        }
        guard let peripheral = discoveredPeripherals[watch.id] else {
            throw WatchConnectionError.watchNotFound
        }

        centralManager.stopScan()
        pendingWatch = WatchConnectionTarget(
            id: watch.id,
            name: peripheral.name ?? watch.name,
            model: watch.model
        )
        peripheral.delegate = self

        // Held for the length of the handshake, and cleared with the
        // continuation: a phase reported against a connect that has already
        // finished would move the app off `connected`.
        handshakePhaseReporter = reportingPhase
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

    public func disconnect(from watch: ConnectedWatch) async {
        // Stop the reconnection machinery first: a scheduled retry captured
        // its peripheral by value and would otherwise undo this disconnect.
        if reconnects.isFollowingOrIdle(watch.id) {
            reconnects.stop()
        }
        guard let peripheral = discoveredPeripherals[watch.id]
            ?? (connectedPeripheral?.watchID == watch.id ? connectedPeripheral : nil) else {
            return
        }
        switch peripheral.state {
        case .connected, .disconnecting:
            // Only expect a disconnect callback when a link actually exists;
            // a stale marker would suppress reconnection after a later drop.
            reconnects.expectDisconnect(of: watch.id)
        case .connecting:
            // A pending connect being withdrawn may or may not come back as a
            // disconnect, so no marker is left to go stale. The chase has
            // already stopped above, which is all a callback would do.
            if connectionContinuation == nil, pendingWatch?.id == watch.id {
                pendingWatch = nil
            }
        default:
            break
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
        try await session.sendAppMessage(applicationID: applicationID, tuples: tuples)
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

        // Strongest signal first; a watch that was looked up rather than heard
        // has none and sorts after every watch that was.
        let watches = scanResults.values.sorted { lhs, rhs in
            (lhs.signalStrength ?? Int.min) > (rhs.signalStrength ?? Int.min)
        }
        scanContinuation?.resume(returning: watches)
        scanContinuation = nil
    }

    func failScan(_ error: WatchConnectionError) {
        centralManager.stopScan()
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        scanContinuation?.resume(throwing: error)
        scanContinuation = nil
    }

    func finishConnection(
        peripheral: CBPeripheral,
        information: WatchVersionInformation
    ) {
        guard let watch = pendingWatch else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let connectedWatch = ConnectedWatch(
            id: peripheral.watchID,
            name: watch.name,
            // The version's own platform byte wins; the discovered model is
            // the fallback for a platform this app has no table entry for.
            model: WatchModel(hardwarePlatform: information.hardwarePlatform) ?? watch.model,
            batteryLevel: link.latestBatteryLevel,
            version: information
        )
        self.connectedWatch = connectedWatch
        let initialConnectionContinuation = connectionContinuation
        initialConnectionContinuation?.resume(returning: connectedWatch)
        connectionContinuation = nil
        handshakePhaseReporter = nil
        pendingWatch = nil
        connectedPeripheral = peripheral
        reconnects.follow(watch)
        if initialConnectionContinuation == nil {
            eventContinuation?.yield(.watchUpdated(connectedWatch))
        }
        startHealthChecks(on: peripheral)
        session.linkOpened()
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
            await DiagnosticLog.shared.record(
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
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
        handshakePhaseReporter = nil
        // Withdraw the pending connect request: CoreBluetooth otherwise keeps
        // it queued forever and a late didConnect would create a session the
        // app no longer expects.
        if let pending = pendingWatch,
           let peripheral = discoveredPeripherals[pending.id] {
            cancelLink(peripheral, reason: "the connect attempt failed: \(error.logDescription)")
        }
        pendingWatch = nil
        endLink()
        failWorkInFlight(error)
    }

    func advertisedWatch(from advertisementData: [String: Any]) -> WatchAdvertisement.AdvertisedWatch? {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return WatchAdvertisement.watch(
            advertisesPebbleService: serviceUUIDs.contains(Self.ppogService)
                || serviceUUIDs.contains(Self.pairingService),
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: [UInt8](
                advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
            )
        )
    }

    func updateBatteryLevel(from bytes: [UInt8]) {
        guard let batteryLevel = BatteryLevelCodec.decode(bytes) else {
            return
        }

        link.latestBatteryLevel = batteryLevel
        guard var watch = connectedWatch else {
            return
        }
        watch.batteryLevel = batteryLevel
        connectedWatch = watch
        eventContinuation?.yield(.watchUpdated(watch))
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
}
