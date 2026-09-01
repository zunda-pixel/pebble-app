public import CoreBluetooth
import DequeModule
public import Foundation
import MemberwiseInit

@MemberwiseInit(.fileprivate)
fileprivate struct PendingAppMessage {
    var applicationID: UUID
    var tuples: [AppMessageTuple]
    var continuation: CheckedContinuation<Void, any Error>
}

private final class NotificationObserverStorage: @unchecked Sendable {
    var observers: [any NSObjectProtocol] = []

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
public final class CoreBluetoothPebbleClient: NSObject, PebbleClient {
    /// Which side of the link hosts the protocol service.
    private enum TransportMode: Equatable {
        /// The watch hosts it and the phone writes to a characteristic.
        case reversed
        /// The phone hosts it and notifies the watch, which subscribed to it.
        case forward
    }

    /// Where a connection stands with the watch's pairing service.
    private enum PairingState: Equatable {
        /// Services have not been inspected yet.
        case unknown
        /// Waiting for the watch to report its connectivity status.
        case checking
        /// The watch has been asked to pair; waiting for the user to accept.
        case pairing
        /// The link is bonded, or the watch has no pairing service.
        case ready
    }

    private static var ppogService = CBUUID(string: "40000000-328E-0FBB-C642-1AA6699BDADA")
    /// Advertised by watches that are not bonded yet, including after a reset.
    private static var pairingService = CBUUID(string: "0000FED9-0000-1000-8000-00805F9B34FB")
    private static var connectivityCharacteristic = CBUUID(string: "00000001-328E-0FBB-C642-1AA6699BDADA")
    private static var pairingTriggerCharacteristic = CBUUID(string: "00000002-328E-0FBB-C642-1AA6699BDADA")
    private static var connectionParametersCharacteristic = CBUUID(string: "00000005-328E-0FBB-C642-1AA6699BDADA")
    private static var ppogNotifyCharacteristic = CBUUID(string: "40000001-328E-0FBB-C642-1AA6699BDADA")
    private static var ppogWriteCharacteristic = CBUUID(string: "40000003-328E-0FBB-C642-1AA6699BDADA")
    private static var batteryService = CBUUID(string: "180F")
    private static var batteryLevelCharacteristic = CBUUID(string: "2A19")

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var scanResults: [String: DiscoveredPebble] = [:]
    private var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredPebble], any Error>?
    private var connectionContinuation: CheckedContinuation<PebbleDevice, any Error>?
    private var pendingDevice: DiscoveredPebble?
    private var activeWriteCharacteristic: CBCharacteristic?
    private var activeBatteryCharacteristic: CBCharacteristic?
    private var activePairingTriggerCharacteristic: CBCharacteristic?
    private var ppogNotifyCharacteristicToSubscribe: CBCharacteristic?
    private var pairingState = PairingState.unknown
    /// Which side hosts the protocol service for this connection.
    private var transportMode = TransportMode.reversed
    private var pairingTimeoutTask: Task<Void, Never>?
    /// Whether this link already answered a reset request. The side that
    /// answers one must not send a second ResetComplete afterwards; the watch
    /// reads that as a request to tear the session down again.
    private var hasSentResetComplete = false
    private var connectedPeripheral: CBPeripheral?
    private var connectedDevice: PebbleDevice?
    private var latestBatteryLevel: Int?
    private var ppogSession: PPoGSession?
    private var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?
    private var pendingGattWrites: Deque<Data> = []
    private var intentionalDisconnectIdentifiers: Set<String> = []
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var pongTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectBackoff = PebbleReconnectBackoff()
    private var transferTimeoutTask: Task<Void, Never>?
    private var reconnectDevice: DiscoveredPebble?
    private var pendingPingCookie: UInt32?
    private var nextPingCookie: UInt32 = 1
    private var isAutomaticReconnect = false
    private var activeTransferSession: PutBytesTransferSession?
    private var completedTransferCookie: UInt32?
    private var firmwareResponseContinuation: CheckedContinuation<Void, any Error>?
    private var firmwareResponseTimeoutTask: Task<Void, Never>?
    private var waitingForFirmwareStart = false
    /// Set for the whole of `installFirmware`, transfers and all.
    private var isInstallingFirmware = false
    private var pendingInstallCookie: UInt32?
    private var transferContinuation: CheckedContinuation<Void, any Error>?
    private var nextBlobDBToken: UInt16 = 1
    private var pendingBlobDBToken: UInt16?
    private var acceptedBlobDBStatuses: [BlobDBStatus] = []
    private var blobDBContinuation: CheckedContinuation<Void, any Error>?
    private var blobDBTimeoutTask: Task<Void, Never>?
    private var appReorderContinuation: CheckedContinuation<Void, any Error>?
    private var appReorderTimeoutTask: Task<Void, Never>?
    private var nextAppMessageTransactionID: UInt8 = 0
    private var queuedAppMessages: Deque<PendingAppMessage> = []
    private var activeAppMessage: PendingAppMessage?
    private var activeAppMessageTransactionID: UInt8?
    private var appMessageTimeoutTask: Task<Void, Never>?
    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()
    private var screenshotCollector: ScreenshotCollector?
    private var screenshotContinuation: CheckedContinuation<PebbleScreenshot, any Error>?
    private var logDumpCookie: UInt32?
    private var nextLogDumpCookie: UInt32 = 1
    private var logDumpLines: [WatchLogLine] = []
    private var logDumpContinuation: CheckedContinuation<[WatchLogLine]?, any Error>?
    private var getBytesCollector: GetBytesCollector?
    private var getBytesContinuation: CheckedContinuation<[UInt8], any Error>?
    private var nextGetBytesTransactionID: UInt8 = 1
    /// Each pull keeps its own clock: the watch answers a screenshot in one
    /// burst and a coredump over a minute or more, so one timeout for both
    /// would either give up early or hang about.
    private var screenshotTimeoutTask: Task<Void, Never>?
    private var logDumpTimeoutTask: Task<Void, Never>?
    private var getBytesTimeoutTask: Task<Void, Never>?

    /// Identifies this client in diagnostics. Several clients can be alive at
    /// once, one per watch, and their logs are otherwise indistinguishable.
    private let clientTag: String

    public init(restoreIdentifier: String = "dev.pebble.central") {
        clientTag = String(restoreIdentifier.split(separator: ".").last ?? "central")
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        )
        observeSystemTimeChanges()
        // Watches inspect the phone's GATT database right after connecting, so
        // the phone-hosted protocol service has to exist before that.
        PebbleGattServer.shared.start()
    }

    /// Single funnel for dropping a link, so diagnostics always name whoever
    /// did it. A locally cancelled link arrives back as a disconnect with no
    /// error, which is indistinguishable from the watch going away.
    private func cancelLink(_ peripheral: CBPeripheral, reason: String) {
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
            // The model is not recoverable without advertisement data, so only
            // hinted watches can be returned.
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
        // A manual connect supersedes any automatic reconnection in flight.
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDevice = nil
        isAutomaticReconnect = false
        reconnectBackoff.reset()
        if let previousPeripheral = connectedPeripheral {
            intentionalDisconnectIdentifiers.insert(previousPeripheral.identifier.uuidString)
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
        // CoreBluetooth knows the name of a bonded watch even when the caller
        // only had a stored one, or none at all.
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
        if reconnectDevice == nil || reconnectDevice?.id == device.id {
            reconnectTask?.cancel()
            reconnectTask = nil
            reconnectDevice = nil
            isAutomaticReconnect = false
            reconnectBackoff.reset()
        }
        guard let peripheral = discoveredPeripherals[device.id]
            ?? (connectedPeripheral?.identifier.uuidString == device.id ? connectedPeripheral : nil) else {
            return
        }
        if peripheral.state != .disconnected {
            // Only expect a disconnect callback when a link actually exists;
            // a stale marker would suppress reconnection after a later drop.
            intentionalDisconnectIdentifiers.insert(device.id)
        }
        stopHealthChecks()
        cancelLink(peripheral, reason: "the app asked to disconnect")
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        await PebbleDiagnostics.shared.recordFrame(direction: "out", frame: frame)
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
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
    }

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard appReorderContinuation == nil else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await withCheckedThrowingContinuation { continuation in
            appReorderContinuation = continuation
            do {
                try sendFrame(AppReorderCodec.frame(applicationIDs: applicationIDs), to: peripheral)
                appReorderTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.failAppReorder(PebbleConnectionError.connectionTimedOut)
                }
            } catch {
                failAppReorder(error)
            }
        }
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        try sendFrame(AppFetchCodec.responseFrame(status: status), to: peripheral)
    }

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard connectedPeripheral != nil, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        try await withCheckedThrowingContinuation { continuation in
            queuedAppMessages.append(PendingAppMessage(
                applicationID: applicationID,
                tuples: tuples,
                continuation: continuation
            ))
            startNextAppMessageIfPossible()
        }
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
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

    /// Asks the watch to describe itself again. What it answers — firmware
    /// version, language pack, capabilities — arrives as `deviceUpdated`.
    public func refreshDeviceInformation() async throws {
        guard let peripheral = connectedPeripheral else { throw PebbleConnectionError.disconnected }
        try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
    }

    /// Sends a named file, which the watch keeps under that name once the
    /// install command lands. A language pack is filed as `lang`.
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
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
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

        try await withCheckedThrowingContinuation { continuation in
            transferContinuation = continuation
            do {
                try handleTransferActions([firstAction], peripheral: peripheral)
                updateTransferTimeout()
            } catch {
                failTransfer(error)
            }
        }
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // Two installs at once would share one slot for the control reply and
        // one flag for "an install is running": the second would strand the
        // first on a continuation nobody holds, and clearing the flag on the
        // way out would then suppress every keepalive for the rest of the
        // link. Claiming the flag here, with nothing awaited in between, keeps
        // it to one.
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
        guard firmwareResponseContinuation == nil else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        self.waitingForFirmwareStart = waitingForStart
        try await withCheckedThrowingContinuation { continuation in
            firmwareResponseContinuation = continuation
            do { try sendFrame(frame, to: peripheral) }
            catch { finishFirmwareControl(throwing: error); return }
            firmwareResponseTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.finishFirmwareControl(throwing: PebbleConnectionError.connectionTimedOut)
            }
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
        // A stale record means the watch already holds this app's setting.
        try await performBlobDBOperation(acceptedStatuses: [.success, .dataStale]) { token in
            NotificationAppsCodec.insertFrame(app: app, token: token)
        }
    }

    public func removeNotificationSourceApp(bundleID: String) async throws {
        try await performBlobDBOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            NotificationAppsCodec.deleteFrame(bundleID: bundleID, token: token)
        }
    }

    public func writeWeather(_ report: PebbleWeatherReport) async throws {
        // A stale record means the watch already holds exactly this forecast.
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
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard screenshotContinuation == nil else {
            throw WatchPullError.operationAlreadyInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            screenshotContinuation = continuation
            screenshotCollector = ScreenshotCollector()
            do {
                try sendFrame(ScreenshotCodec.requestFrame(), to: peripheral)
                screenshotTimeoutTask = quietTimeout(seconds: 30) { [weak self] in
                    self?.finishScreenshot(.failure(PebbleConnectionError.connectionTimedOut))
                }
            } catch {
                finishScreenshot(.failure(error))
            }
        }
    }

    public func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard logDumpContinuation == nil else {
            throw WatchPullError.operationAlreadyInProgress
        }
        let cookie = nextLogDumpCookie
        nextLogDumpCookie &+= 1
        return try await withCheckedThrowingContinuation { continuation in
            logDumpContinuation = continuation
            logDumpCookie = cookie
            logDumpLines = []
            do {
                try sendFrame(
                    LogDumpCodec.requestFrame(generation: generation, cookie: cookie),
                    to: peripheral
                )
                logDumpTimeoutTask = quietTimeout(seconds: 30) { [weak self] in
                    self?.finishLogDump(.failure(PebbleConnectionError.connectionTimedOut))
                }
            } catch {
                finishLogDump(.failure(error))
            }
        }
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard getBytesContinuation == nil else {
            throw WatchPullError.operationAlreadyInProgress
        }
        let transactionID = nextGetBytesTransactionID
        nextGetBytesTransactionID &+= 1
        return try await withCheckedThrowingContinuation { continuation in
            getBytesContinuation = continuation
            getBytesCollector = GetBytesCollector(transactionID: transactionID)
            do {
                try sendFrame(
                    GetBytesCodec.requestFrame(request, transactionID: transactionID),
                    to: peripheral
                )
                // A coredump is a hundred kilobytes over a link that manages a
                // few of them a second, so this waits for the watch to go quiet
                // rather than for the whole thing.
                getBytesTimeoutTask = quietTimeout(seconds: 60) { [weak self] in
                    self?.finishGetBytes(.failure(PebbleConnectionError.connectionTimedOut))
                }
            } catch {
                finishGetBytes(.failure(error))
            }
        }
    }

    /// A deadline that measures silence rather than the whole transfer: the
    /// watch sends an object in chunks and each one puts the deadline back, so
    /// a large but healthy transfer is not cut off while a stalled one is.
    private func quietTimeout(
        seconds: Int,
        onExpiry: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, self != nil else { return }
            onExpiry()
        }
    }

    /// Everything the watch was in the middle of sending is over when the link
    /// is: none of it resumes, and a caller left waiting would wait for ever.
    private func failPulls(_ error: any Error) {
        finishScreenshot(.failure(error))
        finishLogDump(.failure(error))
        finishGetBytes(.failure(error))
    }

    private func finishScreenshot(_ result: Result<PebbleScreenshot, any Error>) {
        screenshotTimeoutTask?.cancel()
        screenshotTimeoutTask = nil
        screenshotCollector = nil
        guard let continuation = screenshotContinuation else { return }
        screenshotContinuation = nil
        continuation.resume(with: result)
    }

    private func finishLogDump(_ result: Result<[WatchLogLine]?, any Error>) {
        logDumpTimeoutTask?.cancel()
        logDumpTimeoutTask = nil
        logDumpCookie = nil
        logDumpLines = []
        guard let continuation = logDumpContinuation else { return }
        logDumpContinuation = nil
        continuation.resume(with: result)
    }

    private func finishGetBytes(_ result: Result<[UInt8], any Error>) {
        getBytesTimeoutTask?.cancel()
        getBytesTimeoutTask = nil
        getBytesCollector = nil
        guard let continuation = getBytesContinuation else { return }
        getBytesContinuation = nil
        continuation.resume(with: result)
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
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard blobDBContinuation == nil else {
            throw BlobDBClientError.operationAlreadyInProgress
        }

        let token = nextBlobDBToken
        nextBlobDBToken &+= 1
        try await withCheckedThrowingContinuation { continuation in
            pendingBlobDBToken = token
            acceptedBlobDBStatuses = acceptedStatuses
            blobDBContinuation = continuation
            do {
                try sendFrame(try frame(token), to: peripheral)
                blobDBTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.failBlobDBOperation(PebbleConnectionError.connectionTimedOut)
                }
            } catch {
                failBlobDBOperation(error)
            }
        }
    }

    private func waitForBluetooth() async throws {
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

    private func failScan(_ error: PebbleConnectionError) {
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
        reconnectDevice = device
        reconnectBackoff.reset()
        isAutomaticReconnect = false
        if initialConnectionContinuation == nil {
            eventContinuation?.yield(.deviceUpdated(connectedDevice))
        }
        startHealthChecks(on: peripheral)
        startNextAppMessageIfPossible()
    }

    /// Routes a transport failure on a specific peripheral: an in-flight
    /// initial connect fails immediately, while an established (or
    /// automatically reconnecting) link is torn down at the Bluetooth level so
    /// that didDisconnectPeripheral drives the reconnect/backoff flow.
    private func abortLink(_ peripheral: CBPeripheral, error: PebbleConnectionError) {
        if connectionContinuation != nil {
            failConnection(error)
            return
        }
        cancelLink(peripheral, reason: "transport failure: \(error.logDescription)")
    }

    private func failConnection(_ error: PebbleConnectionError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        pairingState = .unknown
        transportMode = .reversed
        hasSentResetComplete = false
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
        failPulls(error)
        failAppReorder(error)
        failAllAppMessages(error)
        finishFirmwareControl(throwing: error)
    }

    private func model(from advertisementData: [String: Any]) -> PebbleWatchModel? {
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

    private func write(_ packet: PPoGPacket, to peripheral: CBPeripheral) throws {
        recordPPoGPacket(packet, direction: "out")
        let bytes = try packet.encoded(for: .one)
        if transportMode == .forward {
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

    private func flushWrites(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        while peripheral.canSendWriteWithoutResponse,
              !pendingGattWrites.isEmpty {
            let value = pendingGattWrites.removeFirst()
            peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
        }
    }

    private func handle(
        _ actions: [PPoGSessionAction],
        peripheral: CBPeripheral
    ) throws {
        // A batch is worked through to the end before any failure in it is
        // raised. The watch coalesces frames for unrelated endpoints into one
        // delivery and the session queues the acknowledgement behind that
        // delivery, so giving up on the first unusable frame would drop the
        // reply the app is waiting for — and drop the acknowledgement, which
        // makes the watch retransmit the whole window. The first failure is
        // still raised, so callers keep reporting it the way they always did;
        // it just waits until there is nothing left to lose by it.
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

    private func sendFrame(
        _ frame: PebbleProtocolFrame,
        to peripheral: CBPeripheral
    ) throws {
        guard var session = ppogSession else {
            throw PebbleConnectionError.disconnected
        }

        Task { await PebbleDiagnostics.shared.recordFrame(direction: "out", frame: frame) }
        let bytes = try frame.encoded()
        let maximumPacketSize = transportMode == .forward
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
        if frame.endpoint == PingPongCodec.endpoint {
            try processPingPong(frame, peripheral: peripheral)
            return
        }

        // "I do not know that endpoint" is still an answer: recovery firmware
        // replies this way to a ping, and waiting for a pong that cannot come
        // would drop a link the watch is holding up perfectly well.
        if frame.rejectedEndpoint == PingPongCodec.endpoint {
            clearPendingPing()
            return
        }

        if PhoneVersionCodec.isRequest(frame) {
            #if os(macOS)
            let operatingSystem = PhoneOperatingSystem.macOS
            #else
            let operatingSystem = PhoneOperatingSystem.iOS
            #endif
            try sendFrame(PhoneVersionCodec.responseFrame(operatingSystem: operatingSystem), to: peripheral)
            return
        }

        if frame.endpoint == AppFetchCodec.endpoint {
            eventContinuation?.yield(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))
            return
        }

        if frame.endpoint == HealthSyncCodec.endpoint {
            eventContinuation?.yield(.healthSyncCompleted(try HealthSyncResponseCodec.decode(frame)))
            return
        }

        if frame.endpoint == HealthDataLoggingCodec.endpoint {
            let result = try healthDataLoggingProcessor.process(frame)
            if let response = result.response { try sendFrame(response, to: peripheral) }
            if !result.samples.isEmpty { eventContinuation?.yield(.healthSamplesReceived(result.samples)) }
            return
        }

        if frame.endpoint == TimelineActionCodec.endpoint {
            let invocation = try TimelineActionCodec.decode(frame)
            eventContinuation?.yield(.timelineActionInvoked(invocation))
            try sendFrame(
                TimelineActionCodec.responseFrame(itemID: invocation.itemID, succeeded: true),
                to: peripheral
            )
            return
        }

        if frame.endpoint == AppRunStateCodec.endpoint {
            eventContinuation?.yield(.appRunStateChanged(try AppRunStateCodec.decode(frame)))
            return
        }

        if frame.endpoint == ScreenshotCodec.endpoint, screenshotCollector != nil {
            do {
                if let screenshot = try screenshotCollector?.accept(frame) {
                    finishScreenshot(.success(screenshot))
                } else {
                    screenshotTimeoutTask?.cancel()
                    screenshotTimeoutTask = quietTimeout(seconds: 30) { [weak self] in
                        self?.finishScreenshot(.failure(PebbleConnectionError.connectionTimedOut))
                    }
                }
            } catch {
                finishScreenshot(.failure(error))
            }
            return
        }

        if frame.endpoint == LogDumpCodec.endpoint, let cookie = logDumpCookie {
            switch try LogDumpCodec.decode(frame, cookie: cookie) {
            case .line(let line):
                logDumpLines.append(line)
                logDumpTimeoutTask?.cancel()
                logDumpTimeoutTask = quietTimeout(seconds: 30) { [weak self] in
                    self?.finishLogDump(.failure(PebbleConnectionError.connectionTimedOut))
                }
            case .done:
                finishLogDump(.success(logDumpLines))
            case .noLogs:
                finishLogDump(.success(nil))
            case nil:
                break
            }
            return
        }

        if frame.endpoint == AppLogCodec.endpoint {
            let (applicationID, line) = try AppLogCodec.decode(frame)
            eventContinuation?.yield(.applicationLogReceived(applicationID: applicationID, line: line))
            return
        }

        if frame.endpoint == GetBytesCodec.endpoint, getBytesCollector != nil {
            do {
                if let bytes = try getBytesCollector?.accept(frame) {
                    finishGetBytes(.success(bytes))
                } else {
                    getBytesTimeoutTask?.cancel()
                    getBytesTimeoutTask = quietTimeout(seconds: 60) { [weak self] in
                        self?.finishGetBytes(.failure(PebbleConnectionError.connectionTimedOut))
                    }
                }
            } catch {
                finishGetBytes(.failure(error))
            }
            return
        }

        if frame.endpoint == ImagingCodec.endpoint {
            eventContinuation?.yield(.imageRequested(try ImagingCodec.decode(frame)))
            return
        }

        if frame.endpoint == AppMessageCodec.endpoint {
            processAppMessage(frame)
            return
        }

        if frame.endpoint == AppReorderCodec.endpoint, appReorderContinuation != nil {
            processAppReorderResponse(frame)
            return
        }

        if frame.endpoint == PutBytesCodec.endpoint, activeTransferSession != nil {
            try processPutBytesResponse(frame, peripheral: peripheral)
            return
        }

        if frame.endpoint == PutBytesCodec.endpoint, pendingInstallCookie != nil {
            // The cookie that comes back is zero, so only the result means
            // anything. The firmware answers install from `prv_do_install`
            // through `prv_cleanup_and_send_response`, which sends the token
            // held in its transfer state — and the commit that had to come
            // first already cleared that state. Holding out for the cookie that
            // was sent leaves the install hanging after the watch has written
            // the firmware and reached 100%.
            let response = try PutBytesCodec.decodeResponse(frame)
            pendingInstallCookie = nil
            response.result == .acknowledgement
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: PutBytesTransferError.negativeAcknowledgement)
            return
        }

        if frame.endpoint == SystemMessageCodec.endpoint, waitingForFirmwareStart {
            waitingForFirmwareStart = false
            try SystemMessageCodec.decodeFirmwareUpdateStartResponse(frame)
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: SystemMessageCodecError.updateRejected)
            return
        }

        if frame.endpoint == BlobDBCodec.endpoint, pendingBlobDBToken != nil {
            processBlobDBResponse(frame)
            return
        }

        // A version response can also arrive after the connection is up,
        // because the app asked again — the watch changes what it reports when
        // a language pack is installed, and that is how the app finds out.
        if frame.endpoint == WatchVersionCodec.endpoint,
           pendingDevice == nil,
           let device = connectedDevice {
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
            eventContinuation?.yield(.deviceUpdated(updated))
            return
        }

        guard frame.endpoint == WatchVersionCodec.endpoint,
              pendingDevice != nil else {
            Task { [tag = clientTag, endpoint = frame.endpoint, payload = frame.payload] in
                await PebbleDiagnostics.shared.record(
                    category: "packet",
                    message: "[\(tag)] nothing handles endpoint \(endpoint): "
                        + payload.hexadecimalString
                )
            }
            return
        }
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
    }

    private func finishFirmwareControl(throwing error: (any Error)? = nil) {
        firmwareResponseTimeoutTask?.cancel()
        firmwareResponseTimeoutTask = nil
        waitingForFirmwareStart = false
        pendingInstallCookie = nil
        if let error { firmwareResponseContinuation?.resume(throwing: error) }
        else { firmwareResponseContinuation?.resume() }
        firmwareResponseContinuation = nil
    }

    private func processAppMessage(_ frame: PebbleProtocolFrame) {
        do {
            switch try AppMessageCodec.decode(frame) {
            case .push(let message):
                eventContinuation?.yield(.appMessageReceived(message))
            case .acknowledgement(let transactionID):
                guard transactionID == activeAppMessageTransactionID else { return }
                finishActiveAppMessage()
            case .negativeAcknowledgement(let transactionID):
                guard transactionID == activeAppMessageTransactionID else { return }
                finishActiveAppMessage(throwing: AppMessageClientError.negativeAcknowledgement)
            }
        } catch {
            // Ignore malformed peer packets without terminating the transport.
        }
    }

    private func startNextAppMessageIfPossible() {
        guard activeAppMessage == nil,
              !queuedAppMessages.isEmpty,
              let peripheral = connectedPeripheral,
              ppogSession != nil else { return }
        let request = queuedAppMessages.removeFirst()
        let transactionID = nextAppMessageTransactionID
        nextAppMessageTransactionID &+= 1
        activeAppMessage = request
        activeAppMessageTransactionID = transactionID
        do {
            try sendFrame(AppMessageCodec.pushFrame(AppMessageData(
                transactionID: transactionID,
                applicationID: request.applicationID,
                tuples: request.tuples
            )), to: peripheral)
            appMessageTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.finishActiveAppMessage(throwing: PebbleConnectionError.connectionTimedOut)
            }
        } catch {
            finishActiveAppMessage(throwing: error)
        }
    }

    private func finishActiveAppMessage(throwing error: (any Error)? = nil) {
        appMessageTimeoutTask?.cancel()
        appMessageTimeoutTask = nil
        let request = activeAppMessage
        activeAppMessage = nil
        activeAppMessageTransactionID = nil
        if let error {
            request?.continuation.resume(throwing: error)
        } else {
            request?.continuation.resume()
        }
        startNextAppMessageIfPossible()
    }

    private func failAllAppMessages(_ error: any Error) {
        appMessageTimeoutTask?.cancel()
        appMessageTimeoutTask = nil
        activeAppMessage?.continuation.resume(throwing: error)
        activeAppMessage = nil
        activeAppMessageTransactionID = nil
        for request in queuedAppMessages {
            request.continuation.resume(throwing: error)
        }
        queuedAppMessages.removeAll()
    }

    private func processPingPong(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        switch try PingPongCodec.decode(frame) {
        case .ping(let cookie):
            try sendFrame(PingPongCodec.frame(for: .pong(cookie: cookie)), to: peripheral)
        case .pong(let cookie):
            guard pendingPingCookie == cookie else {
                return
            }
            clearPendingPing()
        }
    }

    private func clearPendingPing() {
        pendingPingCookie = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
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

    private func sendHealthCheck(on peripheral: CBPeripheral) {
        guard pendingPingCookie == nil else {
            return
        }
        // A transfer in flight already proves the link is alive, and it can
        // keep the watch busy for longer than the pong deadline — a firmware
        // install is megabytes. Pinging through one only risks dropping it.
        // The install also has gaps between its transfers, while the watch
        // commits what it was sent, so the whole install counts.
        guard activeTransferSession == nil, !isInstallingFirmware else {
            return
        }
        // Recovery firmware answers no ping at all. Asking can only end in a
        // dropped link, which is the one thing a watch being recovered cannot
        // afford.
        guard connectedDevice?.isRunningRecoveryFirmware != true else {
            return
        }
        let cookie = nextPingCookie
        nextPingCookie &+= 1
        do {
            try sendFrame(PingPongCodec.frame(for: .ping(cookie: cookie)), to: peripheral)
            pendingPingCookie = cookie
            pongTimeoutTask?.cancel()
            pongTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self?.pendingPingCookie == cookie else {
                    return
                }
                self?.cancelLink(peripheral, reason: "no pong within 15s")
            }
        } catch {
            cancelLink(peripheral, reason: "could not send the health check ping")
        }
    }

    private func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
        pendingPingCookie = nil
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
                failBlobDBOperation(BlobDBClientError.rejected(response.status))
                return
            }
            blobDBTimeoutTask?.cancel()
            blobDBTimeoutTask = nil
            pendingBlobDBToken = nil
            acceptedBlobDBStatuses.removeAll()
            blobDBContinuation?.resume()
            blobDBContinuation = nil
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
            appReorderTimeoutTask?.cancel()
            appReorderTimeoutTask = nil
            appReorderContinuation?.resume()
            appReorderContinuation = nil
        } catch {
            failAppReorder(error)
        }
    }

    private func failAppReorder(_ error: any Error) {
        appReorderTimeoutTask?.cancel()
        appReorderTimeoutTask = nil
        appReorderContinuation?.resume(throwing: error)
        appReorderContinuation = nil
    }

    private func failBlobDBOperation(_ error: any Error) {
        blobDBTimeoutTask?.cancel()
        blobDBTimeoutTask = nil
        pendingBlobDBToken = nil
        acceptedBlobDBStatuses.removeAll()
        blobDBContinuation?.resume(throwing: error)
        blobDBContinuation = nil
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
                transferTimeoutTask?.cancel()
                transferTimeoutTask = nil
                activeTransferSession = nil
                transferContinuation?.resume()
                transferContinuation = nil
            }
        }
    }

    private func updateTransferTimeout() {
        transferTimeoutTask?.cancel()
        transferTimeoutTask = nil
        guard activeTransferSession != nil else {
            return
        }
        transferTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else {
                return
            }
            self?.failTransfer(PebbleConnectionError.connectionTimedOut)
        }
    }

    private func failTransfer(_ error: any Error) {
        transferTimeoutTask?.cancel()
        transferTimeoutTask = nil
        activeTransferSession = nil
        transferContinuation?.resume(throwing: error)
        transferContinuation = nil
    }

    private func clearTransportState() {
        activeWriteCharacteristic = nil
        activeBatteryCharacteristic = nil
        activePairingTriggerCharacteristic = nil
        ppogNotifyCharacteristicToSubscribe = nil
        hasSentResetComplete = false
        pairingState = .unknown
        // Which side hosts the transport is decided per link, from the watch's
        // service list; carrying last link's answer into the next one would
        // send the handshake down a transport nobody is listening on.
        transportMode = .reversed
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
        failPulls(PebbleConnectionError.disconnected)
        failAppReorder(PebbleConnectionError.disconnected)
        // A firmware control exchange is waiting on a reply that the watch can
        // no longer send; saying so now beats a timeout ten seconds later that
        // blames the deadline instead of the dropped link.
        finishFirmwareControl(throwing: PebbleConnectionError.disconnected)
        // A send that was in flight when the link went is over, and so is
        // everything queued behind it. `AppModel` keeps its own list of
        // messages it could not deliver and flushes that on the next
        // connection, so a copy held here would be sent twice — and a caller
        // left awaiting one would wait for a link that may never come back,
        // with nothing left able to resume it.
        failAllAppMessages(PebbleConnectionError.disconnected)
    }

    private func reconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard centralManager.state == .poweredOn else {
            eventContinuation?.yield(.reconnecting(deviceID: device.id))
            scheduleReconnect(to: device, using: peripheral)
            return
        }
        pendingDevice = device
        isAutomaticReconnect = true
        peripheral.delegate = self
        eventContinuation?.yield(.reconnecting(deviceID: device.id))
        centralManager.connect(peripheral)

        // A stalled handshake would otherwise sit in "reconnecting" forever:
        // drop the link after a while so the backoff loop retries.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else {
                return
            }
            self?.cancelLink(peripheral, reason: "the reconnect handshake stalled for 30s")
        }
    }

    private func scheduleReconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let delay = reconnectBackoff.nextDelay()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.reconnect(to: device, using: peripheral)
        }
    }

    private func resumeReconnectAfterPowerOn() {
        guard let device = reconnectDevice,
              connectedDevice == nil,
              connectionContinuation == nil else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The pre-power-cycle CBPeripheral may be invalid; look it up again.
            _ = try? await self.retrieveKnownDevices([device])
            guard self.reconnectDevice?.id == device.id,
                  self.connectedDevice == nil,
                  self.connectionContinuation == nil,
                  let peripheral = self.discoveredPeripherals[device.id] else {
                return
            }
            self.reconnect(to: device, using: peripheral)
        }
    }

    private func updateBatteryLevel(from bytes: [UInt8]) {
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

    private func updateAcknowledgementTimeout(for peripheral: CBPeripheral) {
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
            abortLink(peripheral, error: .connectionTimedOut)
        }
    }
}

public enum PutBytesClientError: Error, Equatable, Sendable {
    case transferAlreadyInProgress
    case firmwareUpdateAlreadyInProgress
}

extension CoreBluetoothPebbleClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = bluetoothWaiters
        bluetoothWaiters.removeAll()

        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
            resumeReconnectAfterPowerOn()
        case .unauthorized:
            waiters.forEach { $0.resume(throwing: PebbleConnectionError.permissionDenied) }
            failScan(.permissionDenied)
            failConnection(.permissionDenied)
        case .unsupported:
            waiters.forEach { $0.resume(throwing: PebbleConnectionError.bluetoothUnsupported) }
            failScan(.bluetoothUnsupported)
            failConnection(.bluetoothUnsupported)
        case .poweredOff, .resetting:
            waiters.forEach { $0.resume(throwing: PebbleConnectionError.bluetoothUnavailable) }
            failScan(.bluetoothUnavailable)
            if connectionContinuation != nil {
                failConnection(.bluetoothUnavailable)
            } else if connectedDevice != nil || isAutomaticReconnect {
                // Keep reconnectDevice so the link resumes when power returns.
                reconnectTask?.cancel()
                reconnectTask = nil
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                pendingDevice = nil
                clearTransportState()
                if let device = reconnectDevice {
                    eventContinuation?.yield(.reconnecting(deviceID: device.id))
                }
            }
        case .unknown:
            bluetoothWaiters.append(contentsOf: waiters)
        @unknown default:
            waiters.forEach { $0.resume(throwing: PebbleConnectionError.bluetoothUnavailable) }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let model = model(from: advertisementData) else {
            return
        }

        let id = peripheral.identifier.uuidString
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        discoveredPeripherals[id] = peripheral
        scanResults[id] = DiscoveredPebble(
            id: id,
            name: advertisedName ?? peripheral.name ?? model.displayName,
            model: model,
            signalStrength: RSSI.intValue
        )
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pendingDevice?.id == peripheral.identifier.uuidString else {
            // A connect request that already timed out or was abandoned; do
            // not let it become a session the app does not know about.
            cancelLink(peripheral, reason: "no connect request was waiting for this link")
            return
        }
        pairingState = .unknown
        transportMode = .reversed
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] link established, discovering services"
            )
        }
        peripheral.discoverServices([Self.pairingService, Self.ppogService, Self.batteryService])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        if isAutomaticReconnect, let device = reconnectDevice {
            pendingDevice = nil
            scheduleReconnect(to: device, using: peripheral)
            return
        }
        failConnection(.connectionFailed)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        PebbleGattServer.shared.unregister(centralID: peripheral.identifier.uuidString)
        Task { [tag = clientTag, reconnecting = isReconnecting, message = error?.localizedDescription] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] link dropped reconnecting=\(reconnecting) error=\(message ?? "none")"
            )
        }

        let identifier = peripheral.identifier.uuidString
        let wasConnected = connectedDevice != nil
        let wasIntentional = intentionalDisconnectIdentifiers.remove(identifier) != nil
        let deviceToReconnect = reconnectDevice
        if pendingDevice?.id == peripheral.identifier.uuidString, !isAutomaticReconnect {
            failConnection(.disconnected)
        }
        pendingDevice = nil
        clearTransportState()
        if wasIntentional {
            reconnectDevice = nil
            reconnectBackoff.reset()
            isAutomaticReconnect = false
            return
        }
        if (wasConnected || isAutomaticReconnect), let deviceToReconnect {
            if wasConnected {
                reconnect(to: deviceToReconnect, using: peripheral)
            } else {
                // The reconnect handshake itself failed; back off before retrying.
                scheduleReconnect(to: deviceToReconnect, using: peripheral)
            }
            return
        }
        if wasConnected && !wasIntentional {
            eventContinuation?.yield(.disconnected(.disconnected))
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            peripheral.delegate = self
            discoveredPeripherals[peripheral.identifier.uuidString] = peripheral
        }
    }
}

extension CoreBluetoothPebbleClient: CBPeripheralDelegate {
    /// The watch publishes its protocol service once the link is encrypted,
    /// which invalidates iOS's cached service list. This is the signal that a
    /// fresh discovery will actually return it.
    public func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        guard pendingDevice?.id == peripheral.identifier.uuidString
            || connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }
        Task { [tag = clientTag, uuids = invalidatedServices.map(\.uuid.uuidString)] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] watch invalidated [\(uuids.joined(separator: ","))]"
            )
        }
        peripheral.discoverServices([Self.pairingService, Self.ppogService, Self.batteryService])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            abortLink(peripheral, error: .protocolNegotiationFailed)
            return
        }
        let services = peripheral.services ?? []
        Task { [tag = clientTag, uuids = services.map(\.uuid.uuidString)] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] discovered services [\(uuids.joined(separator: ","))]"
            )
        }

        // The pairing service tells us whether the link is bonded and lets us
        // ask the watch to start pairing. A watch that is not bonded yet only
        // exposes this one, so the protocol service is looked for again once
        // pairing finishes.
        if pairingState == .unknown {
            if let pairingService = services.first(where: { $0.uuid == Self.pairingService }) {
                pairingState = .checking
                peripheral.discoverCharacteristics(
                    [
                        Self.connectivityCharacteristic,
                        Self.pairingTriggerCharacteristic,
                        Self.connectionParametersCharacteristic,
                    ],
                    for: pairingService
                )
            } else {
                pairingState = .ready
            }
        }

        if let service = services.first(where: { $0.uuid == Self.ppogService }) {
            endForwardTransport(on: peripheral)
            peripheral.discoverCharacteristics(
                [Self.ppogNotifyCharacteristic, Self.ppogWriteCharacteristic],
                for: service
            )
        } else {
            // No protocol service of its own: the watch expects the phone to
            // host one and will connect to it as a GATT client. This has to be
            // decided now, because the watch inspects the phone's services
            // right after connecting and does not come back for a second look.
            startForwardTransport(on: peripheral)
        }

        if let batteryService = services.first(where: { $0.uuid == Self.batteryService }) {
            peripheral.discoverCharacteristics(
                [Self.batteryLevelCharacteristic],
                for: batteryService
            )
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        if service.uuid == Self.batteryService {
            guard error == nil,
                  let characteristic = service.characteristics?.first(where: {
                      $0.uuid == Self.batteryLevelCharacteristic
                  }) else {
                return
            }

            activeBatteryCharacteristic = characteristic
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            return
        }

        if service.uuid == Self.pairingService {
            guard error == nil,
                  let characteristics = service.characteristics,
                  let connectivity = characteristics.first(where: { $0.uuid == Self.connectivityCharacteristic }) else {
                // Without the connectivity characteristic there is nothing to
                // wait for; a watch that needs pairing will fail later anyway.
                pairingState = .ready
                startProtocolIfReady(on: peripheral)
                return
            }
            activePairingTriggerCharacteristic = characteristics.first {
                $0.uuid == Self.pairingTriggerCharacteristic
            }
            // Asking for a faster connection interval, as the reference does.
            // Older firmware, including recovery, may not offer this at all.
            if let parameters = characteristics.first(where: {
                $0.uuid == Self.connectionParametersCharacteristic
            }) {
                if parameters.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: parameters)
                }
                if parameters.properties.contains(.write) {
                    peripheral.writeValue(Data([0x00, 0x01]), for: parameters, type: .withResponse)
                }
            }
            if connectivity.properties.contains(.notify) || connectivity.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: connectivity)
            }
            peripheral.readValue(for: connectivity)
            return
        }

        guard error == nil,
              let characteristics = service.characteristics,
              let notifyCharacteristic = characteristics.first(where: { $0.uuid == Self.ppogNotifyCharacteristic }),
              let writeCharacteristic = characteristics.first(where: { $0.uuid == Self.ppogWriteCharacteristic }) else {
            abortLink(peripheral, error: .protocolNegotiationFailed)
            return
        }

        activeWriteCharacteristic = writeCharacteristic
        ppogNotifyCharacteristicToSubscribe = notifyCharacteristic
        startProtocolIfReady(on: peripheral)
    }

    /// Subscribes to the protocol characteristic once the link is known to be
    /// bonded. Subscribing before that fails on a watch that is not paired yet.
    private func startProtocolIfReady(on peripheral: CBPeripheral) {
        guard pairingState == .ready, ppogSession == nil else {
            return
        }
        switch transportMode {
        case .reversed:
            guard let notifyCharacteristic = ppogNotifyCharacteristicToSubscribe else {
                return
            }
            ppogNotifyCharacteristicToSubscribe = nil
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        case .forward:
            // The session opens as soon as the watch subscribes to the
            // phone-hosted characteristic; until then there is nowhere to send.
            guard PebbleGattServer.shared.isSubscribed(centralID: peripheral.identifier.uuidString) else {
                return
            }
            handleForwardTransportReady(on: peripheral)
        }
    }

    /// Publishes the phone's own protocol service and waits for the watch to
    /// subscribe to it.
    private func startForwardTransport(on peripheral: CBPeripheral) {
        guard transportMode != .forward else {
            return
        }
        transportMode = .forward
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] Watch hosts no protocol service; serving it from the phone"
            )
        }
        PebbleGattServer.shared.start()
        PebbleGattServer.shared.register(
            centralID: peripheral.identifier.uuidString,
            onReceive: { [weak self] bytes in
                self?.handleIncomingProtocolBytes(bytes, from: peripheral)
            },
            onSubscribe: { [weak self] in
                self?.handleForwardTransportReady(on: peripheral)
            },
            onUnsubscribe: { [weak self] in
                guard let self, self.transportMode == .forward else { return }
                self.abortLink(peripheral, error: .disconnected)
            }
        )
    }

    /// Hands the transport back to the watch after the phone had stood in for
    /// it, which is what an unbonded watch forces: it publishes its protocol
    /// service only once the link is encrypted, so the first discovery sees the
    /// pairing service alone and the phone reasonably concludes it has to host
    /// the transport itself. When the watch's service turns up after all, that
    /// guess has to be undone — otherwise `startProtocolIfReady` keeps waiting
    /// for a subscription to the phone's characteristic that will never come,
    /// never subscribes to the watch's, and the connect dies on its deadline.
    ///
    /// Tearing the forward transport down, rather than merely preferring the
    /// other one, is what makes this safe: the registration's unsubscribe
    /// callback would otherwise drop the link, its receive callback would feed
    /// packets in from a transport no longer in use, and `write` would keep
    /// aiming at a characteristic nobody is subscribed to.
    ///
    /// Only while no session exists. Once one is running, the transport it was
    /// opened on is the only one either side knows about.
    private func endForwardTransport(on peripheral: CBPeripheral) {
        guard transportMode == .forward, ppogSession == nil else {
            return
        }
        transportMode = .reversed
        PebbleGattServer.shared.unregister(centralID: peripheral.identifier.uuidString)
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] the watch published its own protocol service; using that instead"
            )
        }
    }

    private func handleForwardTransportReady(on peripheral: CBPeripheral) {
        guard transportMode == .forward, ppogSession == nil, pairingState == .ready else {
            return
        }
        // On this transport the watch opens the session: it sends the reset
        // request once it has subscribed. Starting one from here too leaves
        // both sides mid-handshake, and the watch then drops the link.
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] waiting for the watch to open the session"
            )
        }
    }

    private func handleConnectivity(_ bytes: [UInt8], on peripheral: CBPeripheral) {
        guard let status = PebbleConnectivityStatus(decoding: bytes) else {
            // A watch stuck in a bad state reports a truncated value; it needs
            // a reboot before it can be paired.
            abortLink(peripheral, error: .protocolNegotiationFailed)
            return
        }
        Task {
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(clientTag)] connectivity paired=\(status.isPaired) encrypted=\(status.isEncrypted) error=\(status.pairingError)"
            )
        }
        guard pairingState != .ready else {
            return
        }
        if status.isReadyForProtocol {
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            let wasPairing = pairingState == .pairing
            pairingState = .ready
            if wasPairing {
                // Pairing replaced the connect deadline with its own; give the
                // rest of the handshake a fresh one now that it is done.
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.failConnection(.connectionTimedOut)
                }
            }
            startProtocolIfReady(on: peripheral)
            return
        }
        guard pairingState != .pairing else {
            return
        }
        pairingState = .pairing
        // Only the watch can start bonding: ask it to send a security request,
        // which is what makes iOS show its pairing prompt.
        if let trigger = activePairingTriggerCharacteristic {
            peripheral.writeValue(
                Data(PebblePairingTrigger.value()),
                for: trigger,
                type: trigger.properties.contains(.write) ? .withResponse : .withoutResponse
            )
        }
        // Pairing needs the user to accept a prompt, so it gets its own, much
        // longer deadline than the rest of connecting.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else {
                return
            }
            self?.abortLink(peripheral, error: .connectionTimedOut)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if characteristic.uuid == Self.batteryLevelCharacteristic
            || characteristic.uuid == Self.connectivityCharacteristic
            || characteristic.uuid == Self.connectionParametersCharacteristic {
            return
        }

        guard characteristic.uuid == Self.ppogNotifyCharacteristic,
              error == nil,
              characteristic.isNotifying else {
            abortLink(peripheral, error: .protocolNegotiationFailed)
            return
        }

        do {
            try write(.resetRequest(sequence: 0, version: .one), to: peripheral)
        } catch {
            abortLink(peripheral, error: .protocolNegotiationFailed)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if characteristic.uuid == Self.batteryLevelCharacteristic {
            guard error == nil, let value = characteristic.value else {
                return
            }
            updateBatteryLevel(from: [UInt8](value))
            return
        }

        if characteristic.uuid == Self.connectivityCharacteristic {
            guard error == nil, let value = characteristic.value else {
                return
            }
            handleConnectivity([UInt8](value), on: peripheral)
            return
        }

        if characteristic.uuid == Self.connectionParametersCharacteristic {
            return
        }

        guard characteristic.uuid == Self.ppogNotifyCharacteristic,
              error == nil,
              let value = characteristic.value else {
            abortLink(peripheral, error: .protocolNegotiationFailed)
            return
        }
        handleIncomingProtocolBytes([UInt8](value), from: peripheral)
    }

    /// Feeds one received PPoG packet into the session, whichever transport it
    /// arrived on.
    private func handleIncomingProtocolBytes(_ bytes: [UInt8], from peripheral: CBPeripheral) {
        do {
            let packet = try PPoGPacket(decoding: bytes)
            recordPPoGPacket(packet, direction: "in")
            switch packet {
            case .resetRequest(_, let version):
                guard ppogSession == nil else {
                    handleInSessionReset(on: peripheral)
                    return
                }
                try write(
                    .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                    to: peripheral
                )
                hasSentResetComplete = true
                if version == .zero {
                    return
                }
            case .resetComplete(_, let receiveWindow, let transmitWindow):
                guard ppogSession == nil else {
                    handleInSessionReset(on: peripheral)
                    return
                }
                if !hasSentResetComplete {
                    // Only the side that opened the handshake still owes one.
                    try write(
                        .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                        to: peripheral
                    )
                    hasSentResetComplete = true
                }
                let session = PPoGSession(
                    receiveWindow: min(Int(transmitWindow), 25),
                    transmitWindow: min(Int(receiveWindow), 25)
                )
                Task { [
                    tag = clientTag,
                    watchReceive = receiveWindow,
                    watchTransmit = transmitWindow,
                    receive = session.receiveWindow,
                    transmit = session.transmitWindow,
                    packetSize = transportMode == .forward
                        ? PebbleGattServer.shared.maximumPacketSize(centralID: peripheral.identifier.uuidString)
                        : peripheral.maximumWriteValueLength(for: .withoutResponse)
                ] in
                    await PebbleDiagnostics.shared.record(
                        category: "ppog",
                        message: "[\(tag)] session open: watch rx=\(watchReceive) tx=\(watchTransmit),"
                            + " ours rx=\(receive) tx=\(transmit), packet size=\(packetSize)"
                    )
                }
                ppogSession = session
                // A session always starts on a frame boundary; anything the
                // decoder still holds belongs to a session that is gone.
                frameDecoder = PebbleProtocolFrameDecoder()
                connectedPeripheral = peripheral
                try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
            case .data, .acknowledgement:
                guard var session = ppogSession else {
                    return
                }
                let actions = try session.receive(packet)
                ppogSession = session
                try handle(actions, peripheral: peripheral)
                updateAcknowledgementTimeout(for: peripheral)
            }
        } catch {
            guard ppogSession == nil else {
                // A packet that makes no sense is no reason to drop a working
                // link: the transport re-sends whatever went unacknowledged.
                Task { [tag = clientTag, message = error.localizedDescription] in
                    await PebbleDiagnostics.shared.record(
                        .error,
                        category: "pairing",
                        message: "[\(tag)] ignoring an unusable packet: \(message)"
                    )
                }
                return
            }
            // Still handshaking, so there is no session to fall back on.
            abortLink(peripheral, error: .protocolNegotiationFailed)
        }
    }

    /// Handles a reset the watch sends once a session is already running, which
    /// it only does after its own acknowledgement timeouts have run out. The
    /// session cannot be salvaged from this side, so the link is dropped and
    /// the reconnect flow builds a fresh one.
    /// Records a PPoG handshake packet. The watch judges a session by this
    /// exchange, and data and acknowledgements are far too frequent to log.
    private func recordPPoGPacket(_ packet: PPoGPacket, direction: String) {
        let description: String
        switch packet {
        case .resetRequest(let sequence, _): description = "resetRequest seq=\(sequence)"
        case .resetComplete(let sequence, _, _): description = "resetComplete seq=\(sequence)"
        case .acknowledgement, .data: return
        }
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "ppog",
                message: "[\(tag)] \(direction) \(description)"
            )
        }
    }

    private func handleInSessionReset(on peripheral: CBPeripheral) {
        ppogSession = nil
        frameDecoder = PebbleProtocolFrameDecoder()
        abortLink(peripheral, error: .disconnected)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = activeWriteCharacteristic else {
            return
        }
        flushWrites(to: peripheral, characteristic: characteristic)
    }
}
