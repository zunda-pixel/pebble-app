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

/// What is not `private` here is what the two delegate conformances need, and
/// they are in files of their own — `+Central` for the radio and the link,
/// `+Peripheral` for the watch's own services and the PPoG transport. Swift has
/// no access level for "this type across its files", so the alternative to
/// widening these was keeping two thousand lines together. Everything a caller
/// waits on — the pending replies, the queues, the pulls, the frame
/// dispatch — stayed private, and `internal` reaches no further than this
/// module.
@MainActor
public final class CoreBluetoothPebbleClient: NSObject, PebbleClient {
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
    var discoveredPeripherals: [String: CBPeripheral] = [:]
    var scanResults: [String: DiscoveredPebble] = [:]
    var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredPebble], any Error>?
    var connectionContinuation: CheckedContinuation<PebbleDevice, any Error>?
    var pendingDevice: DiscoveredPebble?
    var activeWriteCharacteristic: CBCharacteristic?
    var activeBatteryCharacteristic: CBCharacteristic?
    var activePairingTriggerCharacteristic: CBCharacteristic?
    var ppogNotifyCharacteristicToSubscribe: CBCharacteristic?
    var setup = LinkSetup()
    var pairingTimeoutTask: Task<Void, Never>?
    var subscriptionWatchdog: Task<Void, Never>?
    var hasRepublishedForThisLink = false
    var connectedPeripheral: CBPeripheral?
    var connectedDevice: PebbleDevice?
    private var latestBatteryLevel: Int?
    var ppogSession: PPoGSession?
    var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?
    private var pendingGattWrites: Deque<Data> = []
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var healthCheckTimeoutTask: Task<Void, Never>?
    let reconnects = ReconnectPolicy()
    private var isAwaitingHealthCheckReply = false
    private var activeTransferSession: PutBytesTransferSession?
    private var completedTransferCookie: UInt32?
    private let firmwareReply = PendingReply<Void>()
    private var waitingForFirmwareStart = false
    private var isInstallingFirmware = false
    private var pendingInstallCookie: UInt32?
    private let transferReply = PendingReply<Void>()
    private var nextBlobDBToken: UInt16 = 1
    private var pendingBlobDBToken: UInt16?
    private var acceptedBlobDBStatuses: [BlobDBStatus] = []
    private let blobDBReply = PendingReply<Void>()
    private let blobDBQueue = BlobDBQueue()
    private let appReorderReply = PendingReply<Void>()
    private let appMessages = AppMessageQueue()
    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()
    private let screenshot = WatchPull<ScreenshotCollector>(timeout: .seconds(30))
    private let logDump = WatchPull<LogDumpCollector>(timeout: .seconds(30))
    private var nextLogDumpCookie: UInt32 = 1
    private let fileBytes = WatchPull<GetBytesCollector>(timeout: .seconds(60))
    private var nextGetBytesTransactionID: UInt8 = 1

    let clientTag: String

    private let restoreIdentifier: String

    public init(restoreIdentifier: String = "dev.pebble.central") {
        self.restoreIdentifier = restoreIdentifier
        clientTag = String(restoreIdentifier.split(separator: ".").last ?? "central")
        super.init()
        appMessages.send = { [weak self] data in
            guard let self else { throw PebbleConnectionError.disconnected }
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
    private func linkedPeripheral() throws -> CBPeripheral {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
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

    public func scan() async throws -> [DiscoveredPebble] {
        try await waitForBluetooth()

        guard scanContinuation == nil else {
            throw PebbleConnectionError.scanAlreadyInProgress
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

    public func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble] {
        try await waitForBluetooth()

        // A bonded Pebble stays connected at the system level and stops
        // advertising, so it has to be looked up instead of scanned for.
        let hintsByID = Dictionary(hints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var peripherals = centralManager.retrieveConnectedPeripherals(withServices: [Self.ppogService])
        peripherals += centralManager.retrievePeripherals(
            withIdentifiers: hints.compactMap { UUID(uuidString: $0.id) }
        )

        var retrieved: [DiscoveredPebble] = []
        for peripheral in peripherals {
            let id = peripheral.identifier.uuidString
            guard let hint = hintsByID[id], !retrieved.contains(where: { $0.id == id }) else {
                continue
            }
            discoveredPeripherals[id] = peripheral
            let device = DiscoveredPebble(
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

    public func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        try await waitForBluetooth()

        guard connectionContinuation == nil else {
            throw PebbleConnectionError.connectionAlreadyInProgress
        }
        if let connectedDevice, connectedDevice.id == device.id {
            return connectedDevice
        }
        reconnects.stop()
        if let previousPeripheral = connectedPeripheral {
            reconnects.expectDisconnect(of: previousPeripheral.identifier.uuidString)
            cancelLink(previousPeripheral, reason: "a manual connect superseded it")
            clearTransportState()
        }
        if discoveredPeripherals[device.id] == nil {
            _ = try await retrieveKnownDevices([device])
        }
        guard let peripheral = discoveredPeripherals[device.id] else {
            throw PebbleConnectionError.deviceNotFound
        }

        centralManager.stopScan()
        pendingDevice = DiscoveredPebble(
            id: device.id,
            name: peripheral.name ?? device.name,
            model: device.model,
            signalStrength: device.signalStrength
        )
        peripheral.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            centralManager.connect(peripheral)

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

    public func disconnect(from device: PebbleDevice) async {
        // Stop the reconnection machinery first: a scheduled retry captured
        // its peripheral by value and would otherwise undo this disconnect.
        if reconnects.isFollowing(device.id) {
            reconnects.stop()
        }
        guard let peripheral = discoveredPeripherals[device.id]
            ?? (connectedPeripheral?.identifier.uuidString == device.id ? connectedPeripheral : nil) else {
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

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in
            eventContinuation?.finish()
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {
        let peripheral = try linkedPeripheral()
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
    }

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        let peripheral = try linkedPeripheral()
        guard !appReorderReply.isWaiting else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await appReorderReply.wait(timeout: .seconds(20)) {
            try sendFrame(AppReorderCodec.frame(applicationIDs: applicationIDs), to: peripheral)
        }
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

    public func sendNotification(_ notification: PebbleTimelineNotification) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success]) { token in
            try TimelineNotificationCodec.insertFrame(notification, token: token)
        }
    }

    public func upsertTimelinePin(_ pin: PebbleTimelinePin) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success]) { token in
            try TimelinePinCodec.insertFrame(pin, token: token)
        }
    }

    public func deleteTimelinePin(id: UUID) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            TimelinePinCodec.deleteFrame(id: id, token: token)
        }
    }

    public func clearTimelinePins() async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success]) { token in
            TimelinePinCodec.clearFrame(token: token)
        }
    }

    public func upsertTimelineReminder(_ reminder: PebbleTimelinePin) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success]) { token in
            try TimelineReminderCodec.insertFrame(reminder, token: token)
        }
    }

    public func deleteTimelineReminder(id: UUID) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            TimelineReminderCodec.deleteFrame(id: id, token: token)
        }
    }

    public func launchApplication(id: UUID) async throws {
        try await send(AppRunStateCodec.startFrame(applicationID: id))
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await transferObject(bytes, objectType: objectType, appBankID: appBankID, filename: nil)
    }

    public func refreshDeviceInformation() async throws {
        guard let peripheral = connectedPeripheral else { throw PebbleConnectionError.disconnected }
        try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        try await transferObject(bytes, objectType: .file, appBankID: 0, filename: filename)
    }

    private func transferObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String?
    ) async throws {
        completedTransferCookie = nil
        let peripheral = try linkedPeripheral()
        guard activeTransferSession == nil else {
            throw PutBytesClientError.transferAlreadyInProgress
        }

        var session = PutBytesTransferSession(
            bytes: bytes,
            objectType: objectType,
            appBankID: appBankID,
            filename: filename
        )
        let firstAction = try session.start()
        activeTransferSession = session

        try await transferReply.wait(timeout: .seconds(20)) {
            try handleTransferActions([firstAction], peripheral: peripheral)
        }
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // Claimed with nothing awaited in between: a second install would take
        // over the control reply slot and strand the first.
        guard !isInstallingFirmware else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        isInstallingFirmware = true
        defer { isInstallingFirmware = false }
        let total = package.firmware.count + (package.resources?.count ?? 0)
        guard let byteCount = UInt32(exactly: total) else { throw PutBytesTransferError.invalidConfiguration }
        try await sendFirmwareControl(
            SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: byteCount),
            waitingForStart: true
        )
        try await installApplicationObject(
            [UInt8](package.firmware),
            objectType: package.manifest.firmware.type == "recovery" ? .recovery : .firmware,
            appBankID: 0
        )
        guard let firmwareCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
        var cookies = [firmwareCookie]
        if let resources = package.resources {
            try await installApplicationObject([UInt8](resources), objectType: .systemResource, appBankID: 0)
            guard let resourceCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
            cookies.append(resourceCookie)
        }
        for cookie in cookies {
            pendingInstallCookie = cookie
            try await sendFirmwareControl(PutBytesCodec.installFrame(cookie: cookie), waitingForStart: false)
        }
        try await send(SystemMessageCodec.firmwareUpdateCompleteFrame())
    }

    private func sendFirmwareControl(_ frame: PebbleProtocolFrame, waitingForStart: Bool) async throws {
        guard let peripheral = connectedPeripheral else { throw PebbleConnectionError.disconnected }
        guard !firmwareReply.isWaiting else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        self.waitingForFirmwareStart = waitingForStart
        try await firmwareReply.wait(timeout: .seconds(10)) {
            try sendFrame(frame, to: peripheral)
        }
    }

    public func registerApplication(_ metadata: PebbleAppMetadata) async throws {
        // A stale record means the watch already holds this entry and will
        // never accept it again, which is as good as a successful insert.
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            BlobDBCodec.insertApplicationFrame(metadata: metadata, token: token)
        }
    }

    public func unregisterApplication(applicationID: UUID) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            BlobDBCodec.deleteApplicationFrame(applicationID: applicationID, token: token)
        }
    }

    public func writeNotificationSourceApp(_ app: NotificationSourceApp) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            NotificationAppsCodec.insertFrame(app: app, token: token)
        }
    }

    public func removeNotificationSourceApp(bundleID: String) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            NotificationAppsCodec.deleteFrame(bundleID: bundleID, token: token)
        }
    }

    public func writeAppGlance(_ glance: PebbleAppGlance) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            AppGlanceCodec.insertFrame(glance, token: token)
        }
    }

    public func removeAppGlance(applicationID: UUID) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            AppGlanceCodec.deleteFrame(applicationID: applicationID, token: token)
        }
    }

    public func writeWeather(_ report: PebbleWeatherReport) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            WeatherCodec.insertFrame(report: report, token: token)
        }
    }

    public func writeWatchSetting(_ setting: WatchSetting, isOn: Bool) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            WatchSettingsCodec.insertFrame(setting, isOn: isOn, token: token)
        }
    }

    public func writeActivitySettings(_ settings: PebbleActivitySettings) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            HealthSettingsCodec.insertFrame(settings, token: token)
        }
    }

    public func writeHeartRateSettings(_ settings: PebbleHeartRateSettings) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            HealthSettingsCodec.insertFrame(settings, token: token)
        }
    }

    public func writeHealthDay(_ day: PebbleHealthDay) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            HealthStatsCodec.movementFrame(for: day, token: token)
        }
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            HealthStatsCodec.sleepFrame(for: day, token: token)
        }
    }

    public func writeReminderAppState(_ state: PebbleReminderAppState) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            WeatherCodec.reminderAppFrame(state: state, token: token)
        }
    }

    public func sendImage(
        token: UInt8,
        kindValue: UInt8,
        image: PebbleEncodedImage?
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

    public func takeScreenshot() async throws -> PebbleScreenshot {
        let peripheral = try linkedPeripheral()
        return try await screenshot.run(collecting: ScreenshotCollector()) {
            try sendFrame(ScreenshotCodec.requestFrame(), to: peripheral)
        }
    }

    public func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? {
        let peripheral = try linkedPeripheral()
        let cookie = nextLogDumpCookie
        nextLogDumpCookie &+= 1
        let dump = try await logDump.run(collecting: LogDumpCollector(cookie: cookie)) {
            try sendFrame(
                LogDumpCodec.requestFrame(generation: generation, cookie: cookie),
                to: peripheral
            )
        }
        switch dump {
        case .lines(let lines): return lines
        case .noLogs: return nil
        }
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] {
        let peripheral = try linkedPeripheral()
        let transactionID = nextGetBytesTransactionID
        nextGetBytesTransactionID &+= 1
        return try await fileBytes.run(
            collecting: GetBytesCollector(transactionID: transactionID)
        ) {
            try sendFrame(
                GetBytesCodec.requestFrame(request, transactionID: transactionID),
                to: peripheral
            )
        }
    }

    private func failPulls(_ error: any Error) {
        screenshot.finish(.failure(error))
        logDump.finish(.failure(error))
        fileBytes.finish(.failure(error))
    }

    public func writeWeatherLocationOrder(_ orderedIDs: [UUID]) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            WeatherCodec.preferencesFrame(orderedIDs: orderedIDs, token: token)
        }
    }

    public func removeWeather(id: UUID) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            WeatherCodec.deleteFrame(id: id, token: token)
        }
    }

    private func performBlobDBOperation(
        acceptedStatuses: [BlobDBStatus],
        frame: (UInt16) throws -> PebbleProtocolFrame
    ) async throws {
        // Callers take turns rather than being turned away: they are unrelated
        // features on unrelated timers, and the one that lost the race used to
        // report that the watch had refused it.
        try await blobDBQueue.begin()
        defer { blobDBQueue.finish() }
        let peripheral = try linkedPeripheral()

        let token = nextBlobDBToken
        nextBlobDBToken &+= 1
        pendingBlobDBToken = token
        acceptedBlobDBStatuses = acceptedStatuses
        // A frame that cannot even be built fails the caller from inside `wait`,
        // which leaves the token behind for the next answer to match.
        defer {
            pendingBlobDBToken = nil
            acceptedBlobDBStatuses.removeAll()
        }
        try await blobDBReply.wait(timeout: .seconds(20)) {
            try sendFrame(try frame(token), to: peripheral)
        }
    }

    private func waitForBluetooth() async throws {
        startBluetooth()
        switch centralManager.state {
        case .poweredOn:
            return
        case .unauthorized:
            throw PebbleConnectionError.permissionDenied
        case .unsupported:
            throw PebbleConnectionError.bluetoothUnsupported
        case .poweredOff, .resetting:
            throw PebbleConnectionError.bluetoothUnavailable
        case .unknown:
            try await withCheckedThrowingContinuation { continuation in
                bluetoothWaiters.append(continuation)
            }
        @unknown default:
            throw PebbleConnectionError.bluetoothUnavailable
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

    func failScan(_ error: PebbleConnectionError) {
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
        let connectedDevice = PebbleDevice(
            id: peripheral.identifier.uuidString,
            name: device.name,
            model: PebbleWatchModel(hardwarePlatform: information.hardwarePlatform) ?? device.model,
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
        self.connectedDevice = connectedDevice
        let initialConnectionContinuation = connectionContinuation
        initialConnectionContinuation?.resume(returning: connectedDevice)
        connectionContinuation = nil
        pendingDevice = nil
        connectedPeripheral = peripheral
        reconnects.follow(device)
        if initialConnectionContinuation == nil {
            eventContinuation?.yield(.deviceUpdated(connectedDevice))
        }
        startHealthChecks(on: peripheral)
        appMessages.startNextIfPossible()
    }

    /// `step` names what the link was doing. Eleven places report the same
    /// `protocolNegotiationFailed`, and a log that only carries the error says
    /// nothing about which of them a watch stopped at.
    func abortLink(
        _ peripheral: CBPeripheral,
        error: PebbleConnectionError,
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

    func failConnection(_ error: PebbleConnectionError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        setup.reset()
        ppogNotifyCharacteristicToSubscribe = nil
        activePairingTriggerCharacteristic = nil
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
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
        connectedDevice = nil
        latestBatteryLevel = nil
        ppogSession = nil
        pendingGattWrites.removeAll()
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
        completedTransferCookie = nil
        stopHealthChecks()
        failTransfer(error)
        failBlobDBOperation(error)
        blobDBQueue.failAll(error)
        failPulls(error)
        failAppReorder(error)
        appMessages.failAll(error)
        finishFirmwareControl(throwing: error)
    }

    func model(from advertisementData: [String: Any]) -> PebbleWatchModel? {
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
                throw PebbleConnectionError.protocolNegotiationFailed
            }
            return
        }
        guard let characteristic = activeWriteCharacteristic else {
            throw PebbleConnectionError.protocolNegotiationFailed
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
                throw PebbleConnectionError.protocolNegotiationFailed
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
            throw PebbleConnectionError.disconnected
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
        // The audio endpoint sends fifty of these a second and the app answers
        // all of them; the session says what it heard in one line.
        guard frame.endpoint != AudioStreamCodec.endpoint else { return }
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

    private func answerPutBytes(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        if activeTransferSession != nil {
            try processPutBytesResponse(frame, peripheral: peripheral)
            return true
        }
        guard pendingInstallCookie != nil else { return false }
        // The install cookie comes back as zero: the firmware answers from
        // `prv_cleanup_and_send_response`, whose transfer state the preceding
        // commit already cleared.
        let response = try PutBytesCodec.decodeResponse(frame)
        pendingInstallCookie = nil
        response.result == .acknowledgement
            ? finishFirmwareControl()
            : finishFirmwareControl(throwing: PutBytesTransferError.negativeAcknowledgement)
        return true
    }

    private func answerWatchVersion(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        // The watch changes what it reports when a language pack is installed,
        // which is how the app finds out.
        if pendingDevice == nil, let device = connectedDevice {
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
            connectedDevice = updated
            // The health check asks for this once a minute and the answer is
            // almost always the same one; announcing it anyway had the app
            // rewriting its watch library every minute.
            if updated != device {
                eventContinuation?.yield(.deviceUpdated(updated))
            }
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

    private func finishFirmwareControl(throwing error: (any Error)? = nil) {
        waitingForFirmwareStart = false
        pendingInstallCookie = nil
        if let error { firmwareReply.fail(error) } else { firmwareReply.finish() }
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
        guard connectedDevice?.isRunningRecoveryFirmware != true else {
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

    private func processPutBytesResponse(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        guard var session = activeTransferSession else {
            return
        }
        let response = try PutBytesCodec.decodeResponse(frame)
        do {
            let actions = try session.receive(response)
            activeTransferSession = session
            try handleTransferActions(actions, peripheral: peripheral)
            updateTransferTimeout()
        } catch {
            try? sendFrame(PutBytesCodec.abortFrame(cookie: response.cookie), to: peripheral)
            failTransfer(error)
        }
    }

    private func processBlobDBResponse(_ frame: PebbleProtocolFrame) {
        do {
            let response = try BlobDBCodec.decodeResponse(frame)
            guard response.token == pendingBlobDBToken else { return }
            guard acceptedBlobDBStatuses.contains(response.status) else {
                // The status is the watch's whole explanation, and a refusal that
                // only reached the caller as an error value left the log showing a
                // request answered in milliseconds and nothing else.
                Task { [tag = clientTag, status = response.status] in
                    await PebbleDiagnostics.shared.record(
                        .warning,
                        category: "blobdb",
                        message: "[\(tag)] the watch refused the write: \(status)"
                    )
                }
                failBlobDBOperation(BlobDBClientError.rejected(response.status))
                return
            }
            pendingBlobDBToken = nil
            acceptedBlobDBStatuses.removeAll()
            blobDBReply.finish()
        } catch {
            failBlobDBOperation(error)
        }
    }

    private func processAppReorderResponse(_ frame: PebbleProtocolFrame) {
        do {
            let result = try AppReorderCodec.decodeResult(frame)
            guard result == .success else {
                failAppReorder(AppReorderClientError.rejected(result))
                return
            }
            appReorderReply.finish()
        } catch {
            failAppReorder(error)
        }
    }

    private func failAppReorder(_ error: any Error) {
        appReorderReply.fail(error)
    }

    private func failBlobDBOperation(_ error: any Error) {
        pendingBlobDBToken = nil
        acceptedBlobDBStatuses.removeAll()
        blobDBReply.fail(error)
    }

    private func handleTransferActions(
        _ actions: [PutBytesTransferAction],
        peripheral: CBPeripheral
    ) throws {
        for action in actions {
            switch action {
            case .send(let frame):
                try sendFrame(frame, to: peripheral)
            case .progress(let progress):
                eventContinuation?.yield(.transferProgress(progress))
            case .finished:
                completedTransferCookie = activeTransferSession?.completedCookie
                activeTransferSession = nil
                transferReply.finish()
            }
        }
    }

    // Each chunk the watch acknowledges puts the deadline back: a transfer is
    // megabytes and only silence means it has stopped.
    private func updateTransferTimeout() {
        guard activeTransferSession != nil else {
            transferReply.cancelDeadline()
            return
        }
        transferReply.extendDeadline(.seconds(20))
    }

    private func failTransfer(_ error: any Error) {
        activeTransferSession = nil
        transferReply.fail(error)
    }

    func clearTransportState() {
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
        connectedDevice = nil
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
        failTransfer(PebbleConnectionError.disconnected)
        failBlobDBOperation(PebbleConnectionError.disconnected)
        blobDBQueue.failAll(PebbleConnectionError.disconnected)
        failPulls(PebbleConnectionError.disconnected)
        failAppReorder(PebbleConnectionError.disconnected)
        // A firmware control exchange is waiting on a reply that the watch can
        // no longer send; saying so now beats a timeout ten seconds later that
        // blames the deadline instead of the dropped link.
        finishFirmwareControl(throwing: PebbleConnectionError.disconnected)
        // `AppModel` keeps its own list of undelivered messages and flushes it
        // on the next connection, so a copy held here would be sent twice.
        appMessages.failAll(PebbleConnectionError.disconnected)
    }

    func reconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        reconnects.cancelSchedule()
        guard centralManager.state == .poweredOn else {
            eventContinuation?.yield(.reconnecting(deviceID: device.id))
            scheduleReconnect(to: device, using: peripheral)
            return
        }
        pendingDevice = device
        reconnects.beginAutomaticAttempt()
        peripheral.delegate = self
        eventContinuation?.yield(.reconnecting(deviceID: device.id))
        centralManager.connect(peripheral)

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
    func giveUpReconnecting(to device: DiscoveredPebble) {
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

    func scheduleReconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        reconnects.schedule { [weak self] in
            self?.reconnect(to: device, using: peripheral)
        }
    }

    func resumeReconnectAfterPowerOn() {
        guard let device = reconnects.device,
              connectedDevice == nil,
              connectionContinuation == nil else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The pre-power-cycle CBPeripheral may be invalid; look it up again.
            _ = try? await self.retrieveKnownDevices([device])
            guard self.reconnects.device?.id == device.id,
                  self.connectedDevice == nil,
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
        guard var device = connectedDevice else {
            return
        }
        device.batteryLevel = batteryLevel
        connectedDevice = device
        eventContinuation?.yield(.deviceUpdated(device))
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
