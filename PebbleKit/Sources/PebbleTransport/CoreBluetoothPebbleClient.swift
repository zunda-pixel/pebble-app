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

@MainActor
public final class CoreBluetoothPebbleClient: NSObject, PebbleClient {
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
    private var setup = LinkSetup()
    private var pairingTimeoutTask: Task<Void, Never>?
    private var subscriptionWatchdog: Task<Void, Never>?
    private var hasRepublishedForThisLink = false
    private var connectedPeripheral: CBPeripheral?
    private var connectedDevice: PebbleDevice?
    private var latestBatteryLevel: Int?
    private var ppogSession: PPoGSession?
    private var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?
    private var pendingGattWrites: Deque<Data> = []
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var healthCheckTimeoutTask: Task<Void, Never>?
    private let reconnects = ReconnectPolicy()
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
    private var screenshotCollector: ScreenshotCollector?
    private let screenshotReply = PendingReply<PebbleScreenshot>()
    private var logDumpCookie: UInt32?
    private var nextLogDumpCookie: UInt32 = 1
    private var logDumpLines: [WatchLogLine] = []
    private let logDumpReply = PendingReply<[WatchLogLine]?>()
    private var getBytesCollector: GetBytesCollector?
    private let getBytesReply = PendingReply<[UInt8]>()
    private var nextGetBytesTransactionID: UInt8 = 1

    private let clientTag: String

    public init(restoreIdentifier: String = "dev.pebble.central") {
        clientTag = String(restoreIdentifier.split(separator: ".").last ?? "central")
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        )
        appMessages.send = { [weak self] data in
            guard let self, let peripheral = connectedPeripheral, ppogSession != nil else {
                throw PebbleConnectionError.disconnected
            }
            try sendFrame(AppMessageCodec.pushFrame(data), to: peripheral)
        }
        observeSystemTimeChanges()
        // Watches inspect the phone's GATT database right after connecting, so
        // the phone-hosted protocol service has to exist before that.
        PebbleGattServer.shared.start()
    }

    /// A locally cancelled link arrives back as a disconnect with no error,
    /// which is indistinguishable from the watch going away.
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
        guard !appReorderReply.isWaiting else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await appReorderReply.wait(timeout: .seconds(20)) {
            try sendFrame(AppReorderCodec.frame(applicationIDs: applicationIDs), to: peripheral)
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
        try await appMessages.enqueue(applicationID: applicationID, tuples: tuples)
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
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard !screenshotReply.isWaiting else {
            throw WatchPullError.operationAlreadyInProgress
        }
        screenshotCollector = ScreenshotCollector()
        return try await screenshotReply.wait(timeout: .seconds(30)) {
            try sendFrame(ScreenshotCodec.requestFrame(), to: peripheral)
        }
    }

    public func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard !logDumpReply.isWaiting else {
            throw WatchPullError.operationAlreadyInProgress
        }
        let cookie = nextLogDumpCookie
        nextLogDumpCookie &+= 1
        logDumpCookie = cookie
        logDumpLines = []
        return try await logDumpReply.wait(timeout: .seconds(30)) {
            try sendFrame(
                LogDumpCodec.requestFrame(generation: generation, cookie: cookie),
                to: peripheral
            )
        }
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] {
        guard let peripheral = connectedPeripheral, ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        guard !getBytesReply.isWaiting else {
            throw WatchPullError.operationAlreadyInProgress
        }
        let transactionID = nextGetBytesTransactionID
        nextGetBytesTransactionID &+= 1
        getBytesCollector = GetBytesCollector(transactionID: transactionID)
        // A coredump is a hundred kilobytes over a link that manages a few of
        // them a second, so this waits for the watch to go quiet rather than for
        // the whole thing.
        return try await getBytesReply.wait(timeout: .seconds(60)) {
            try sendFrame(
                GetBytesCodec.requestFrame(request, transactionID: transactionID),
                to: peripheral
            )
        }
    }

    private func failPulls(_ error: any Error) {
        finishScreenshot(.failure(error))
        finishLogDump(.failure(error))
        finishGetBytes(.failure(error))
    }

    private func finishScreenshot(_ result: Result<PebbleScreenshot, any Error>) {
        screenshotCollector = nil
        screenshotReply.resume(with: result)
    }

    private func finishLogDump(_ result: Result<[WatchLogLine]?, any Error>) {
        logDumpCookie = nil
        logDumpLines = []
        logDumpReply.resume(with: result)
    }

    private func finishGetBytes(_ result: Result<[UInt8], any Error>) {
        getBytesCollector = nil
        getBytesReply.resume(with: result)
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
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }

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
    private func abortLink(
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

    private func failConnection(_ error: PebbleConnectionError) {
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

    private func sendFrame(
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
        if frame.endpoint == PingPongCodec.endpoint {
            try processPingPong(frame, peripheral: peripheral)
            return
        }

        // "I do not know that endpoint" is still an answer, and a link the watch
        // is holding up perfectly well should not be dropped for it.
        if frame.rejectedEndpoint == WatchVersionCodec.endpoint {
            clearPendingHealthCheck()
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
                    screenshotReply.extendDeadline(.seconds(30))
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
                logDumpReply.extendDeadline(.seconds(30))
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
                    getBytesReply.extendDeadline(.seconds(60))
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

        if frame.endpoint == AppReorderCodec.endpoint, appReorderReply.isWaiting {
            processAppReorderResponse(frame)
            return
        }

        if frame.endpoint == PutBytesCodec.endpoint, activeTransferSession != nil {
            try processPutBytesResponse(frame, peripheral: peripheral)
            return
        }

        if frame.endpoint == PutBytesCodec.endpoint, pendingInstallCookie != nil {
            // The install cookie comes back as zero: the firmware answers from
            // `prv_cleanup_and_send_response`, whose transfer state the
            // preceding commit already cleared.
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

        // The watch changes what it reports when a language pack is installed, which
        // is how the app finds out.
        if frame.endpoint == WatchVersionCodec.endpoint,
           pendingDevice == nil,
           let device = connectedDevice {
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
            return
        }

        guard frame.endpoint == WatchVersionCodec.endpoint,
              pendingDevice != nil else {
            // Audio arrives fifty frames a second and the app answers all of
            // them, so recording each one filled the whole five-hundred-entry
            // report with a single dictation and left nothing to diagnose with.
            // The session says what it heard in one line instead.
            guard frame.endpoint != AudioStreamCodec.endpoint else { return }
            Task { [tag = clientTag, endpoint = frame.endpoint, payload = frame.payload] in
                await PebbleDiagnostics.shared.record(
                    category: "packet",
                    // Every frame is handed to the app as well, so this is only
                    // ever about the transport: reading it as "the app ignored
                    // this" sends a search for a missing feature to the wrong
                    // layer.
                    message: "[\(tag)] the transport has no answer for endpoint \(endpoint): "
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

    private func clearTransportState() {
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

    private func reconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
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
    private func giveUpReconnecting(to device: DiscoveredPebble) {
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

    private func scheduleReconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        reconnects.schedule { [weak self] in
            self?.reconnect(to: device, using: peripheral)
        }
    }

    private func resumeReconnectAfterPowerOn() {
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
            abortLink(peripheral, error: .connectionTimedOut, step: "resending unacknowledged packets")
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
            } else if connectedDevice != nil || reconnects.isAutomatic {
                reconnects.cancelSchedule()
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                pendingDevice = nil
                clearTransportState()
                if let device = reconnects.device {
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
        setup.reset()
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
        if reconnects.isAutomatic, let device = reconnects.device {
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
        let wasIntentional = reconnects.wasExpected(identifier)
        let deviceToReconnect = reconnects.device
        let wasAutomatic = reconnects.isAutomatic
        if pendingDevice?.id == peripheral.identifier.uuidString, !wasAutomatic {
            failConnection(.disconnected)
        }
        pendingDevice = nil
        clearTransportState()
        if wasIntentional {
            reconnects.stop()
            return
        }
        if (wasConnected || wasAutomatic), let deviceToReconnect {
            if wasConnected {
                reconnect(to: deviceToReconnect, using: peripheral)
            } else if reconnects.noteHandshakeFailed() {
                // The link came up and died before a session: worth another go,
                // but not forever.
                scheduleReconnect(to: deviceToReconnect, using: peripheral)
            } else {
                giveUpReconnecting(to: deviceToReconnect)
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
            abortLink(
                peripheral,
                error: .protocolNegotiationFailed,
                step: "discovering services: \(error?.localizedDescription ?? "")"
            )
            return
        }
        let services = peripheral.services ?? []
        Task { [tag = clientTag, uuids = services.map(\.uuid.uuidString)] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] discovered services [\(uuids.joined(separator: ","))]"
            )
        }

        // A watch that is not bonded yet exposes only this service, so the protocol
        // one is looked for again once pairing finishes.
        if setup.pairing == .unknown {
            if let pairingService = services.first(where: { $0.uuid == Self.pairingService }) {
                setup.noteCheckingPairing()
                peripheral.discoverCharacteristics(
                    [
                        Self.connectivityCharacteristic,
                        Self.pairingTriggerCharacteristic,
                        Self.connectionParametersCharacteristic,
                    ],
                    for: pairingService
                )
            } else {
                setup.noteNoPairingService()
            }
        }

        // The transport is not handed back here: a service can be listed and still
        // be unusable, and dropping the phone's one first would leave the link
        // with neither.
        if let service = services.first(where: { $0.uuid == Self.ppogService }) {
            peripheral.discoverCharacteristics(
                [Self.ppogNotifyCharacteristic, Self.ppogWriteCharacteristic],
                for: service
            )
        } else {
            // The watch expects the phone to host the service and connects to it as a
            // GATT client. It inspects the phone right after connecting and does not come
            // back for a second look.
            startForwardTransport(on: peripheral, because: "the watch hosts none")
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
                setup.noteNoPairingService()
                startProtocolIfReady(on: peripheral)
                return
            }
            activePairingTriggerCharacteristic = characteristics.first {
                $0.uuid == Self.pairingTriggerCharacteristic
            }
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
            // iOS keeps its own copy of the watch's database, and a factory reset
            // leaves that copy holding the protocol service with nothing inside it.
            // The watch subscribes to the phone's service while this is going on, so
            // an unusable service is a reason to host the transport rather than to
            // give up on a watch that is talking.
            let found = (service.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ",")
            startForwardTransport(
                on: peripheral,
                because: "the watch's own service is unusable"
                    + " (\(error?.localizedDescription ?? "it offered [\(found)]"))"
            )
            startProtocolIfReady(on: peripheral)
            return
        }

        endForwardTransport(on: peripheral)
        activeWriteCharacteristic = writeCharacteristic
        ppogNotifyCharacteristicToSubscribe = notifyCharacteristic
        startProtocolIfReady(on: peripheral)
    }

    // Subscribing before the link is known to be bonded fails on a watch that is
    // not paired yet.
    private func startProtocolIfReady(on peripheral: CBPeripheral) {
        guard setup.mayStartProtocol, ppogSession == nil else {
            return
        }
        switch setup.transport {
        case .reversed:
            guard let notifyCharacteristic = ppogNotifyCharacteristicToSubscribe else {
                return
            }
            ppogNotifyCharacteristicToSubscribe = nil
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        case .forward:
            guard PebbleGattServer.shared.isSubscribed(centralID: peripheral.identifier.uuidString) else {
                waitForTheWatchToSubscribe(on: peripheral)
                return
            }
            handleForwardTransportReady(on: peripheral)
        }
    }

    private func startForwardTransport(on peripheral: CBPeripheral, because reason: String) {
        guard setup.hostTransportOnPhone() else {
            return
        }
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] serving the protocol from the phone: \(reason)"
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
                guard let self, self.setup.transport == .forward else { return }
                self.abortLink(peripheral, error: .disconnected, step: "hosting the transport: the watch unsubscribed")
            }
        )
    }

    /// Torn down rather than merely deselected: the registration's unsubscribe
    /// callback would otherwise drop the link, and its receive callback would
    /// feed packets in from a transport no longer in use.
    private func endForwardTransport(on peripheral: CBPeripheral) {
        guard ppogSession == nil, setup.handTransportBackToWatch() else {
            return
        }
        PebbleGattServer.shared.unregister(centralID: peripheral.identifier.uuidString)
        Task { [tag = clientTag] in
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(tag)] the watch published its own protocol service; using that instead"
            )
        }
    }

    /// A bonded watch that never subscribes to the phone's service.
    ///
    /// It has to read the phone's GATT database to find the characteristic, and
    /// it caches what it read. Re-adding the service is what makes iOS send a
    /// service-changed indication, which is the only thing that tells a watch
    /// holding a stale cache to look again. Without this the link sits until the
    /// connect deadline and the next attempt does exactly the same, for ever.
    private func waitForTheWatchToSubscribe(on peripheral: CBPeripheral) {
        guard !hasRepublishedForThisLink, subscriptionWatchdog == nil else {
            return
        }
        subscriptionWatchdog = Task { [weak self, tag = clientTag] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.subscriptionWatchdog = nil
            let centralID = peripheral.identifier.uuidString
            guard self.setup.transport == .forward,
                  self.ppogSession == nil,
                  !PebbleGattServer.shared.isSubscribed(centralID: centralID) else {
                return
            }
            self.hasRepublishedForThisLink = true
            await PebbleDiagnostics.shared.record(
                .warning,
                category: "pairing",
                message: "[\(tag)] the watch has not subscribed to the phone's service; publishing it again"
            )
            PebbleGattServer.shared.republish()
        }
    }

    private func handleForwardTransportReady(on peripheral: CBPeripheral) {
        guard setup.transport == .forward, ppogSession == nil, setup.mayStartProtocol else {
            return
        }
        // On this transport the watch sends the reset request once it has subscribed;
        // starting one from here too leaves both sides mid-handshake.
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
            abortLink(
                peripheral,
                error: .protocolNegotiationFailed,
                step: "reading the watch's pairing state: it answered \(bytes.count) bytes"
            )
            return
        }
        Task {
            await PebbleDiagnostics.shared.record(
                category: "pairing",
                message: "[\(clientTag)] connectivity paired=\(status.isPaired) encrypted=\(status.isEncrypted) error=\(status.pairingError)"
            )
        }
        switch setup.apply(status) {
        case .wait:
            return
        case .ready(let wasPairing):
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            if wasPairing {
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
        case .askWatchToPair:
            break
        }
        // Only the watch can start bonding: ask it to send a security request,
        // which is what makes iOS show its pairing prompt.
        if let trigger = activePairingTriggerCharacteristic {
            peripheral.writeValue(
                Data(PebblePairingTrigger.value()),
                for: trigger,
                type: trigger.properties.contains(.write) ? .withResponse : .withoutResponse
            )
        }
        // Pairing waits on the reader accepting a prompt.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else {
                return
            }
            self?.abortLink(peripheral, error: .connectionTimedOut, step: "waiting for the watch to be paired")
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
            abortLink(
                peripheral,
                error: .protocolNegotiationFailed,
                step: "subscribing to the watch's protocol characteristic: \(error?.localizedDescription ?? "it did not turn on")"
            )
            return
        }

        do {
            try write(.resetRequest(sequence: 0, version: .one), to: peripheral)
        } catch {
            abortLink(peripheral, error: .protocolNegotiationFailed, step: "opening the session")
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
            abortLink(
                peripheral,
                error: .protocolNegotiationFailed,
                step: "reading what the watch sent: \(error?.localizedDescription ?? "it was empty")"
            )
            return
        }
        handleIncomingProtocolBytes([UInt8](value), from: peripheral)
    }

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
                _ = setup.claimResetComplete()
                if version == .zero {
                    return
                }
            case .resetComplete(_, let receiveWindow, let transmitWindow):
                guard ppogSession == nil else {
                    handleInSessionReset(on: peripheral)
                    return
                }
                if setup.claimResetComplete() {
                    // Only the side that opened the handshake still owes one.
                    try write(
                        .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                        to: peripheral
                    )
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
                    packetSize = setup.transport == .forward
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
            abortLink(peripheral, error: .protocolNegotiationFailed, step: "handling a packet from the watch")
        }
    }

    // The watch judges a session by this exchange, and data and acknowledgements
    // are far too frequent to log.
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
        abortLink(peripheral, error: .disconnected, step: "the watch asked to start the session over")
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = activeWriteCharacteristic else {
            return
        }
        flushWrites(to: peripheral, characteristic: characteristic)
    }
}
