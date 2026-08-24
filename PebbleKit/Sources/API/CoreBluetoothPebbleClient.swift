public import CoreBluetooth
public import Foundation

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
    private static var ppogNotifyCharacteristic = CBUUID(string: "40000001-328E-0FBB-C642-1AA6699BDADA")
    private static var ppogWriteCharacteristic = CBUUID(string: "40000003-328E-0FBB-C642-1AA6699BDADA")
    private static var batteryService = CBUUID(string: "180F")
    private static var batteryLevelCharacteristic = CBUUID(string: "2A19")
    private static var vendorIdentifiers: Set<UInt16> = [0x0154, 0x0EEA]

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var scanResults: [String: DiscoveredPebble] = [:]
    private var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredPebble], any Error>?
    private var connectionContinuation: CheckedContinuation<PebbleDevice, any Error>?
    private var pendingDevice: DiscoveredPebble?
    private var activeWriteCharacteristic: CBCharacteristic?
    private var activeBatteryCharacteristic: CBCharacteristic?
    private var connectedPeripheral: CBPeripheral?
    private var connectedDevice: PebbleDevice?
    private var latestBatteryLevel: Int?
    private var ppogSession: PPoGSession?
    private var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?
    private var pendingGattWrites: [Data] = []
    private var intentionalDisconnectIdentifiers: Set<String> = []
    private var timeChangeObservers = NotificationObserverStorage()
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?
    private var acknowledgementTimeoutTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var pongTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var transferTimeoutTask: Task<Void, Never>?
    private var reconnectDevice: DiscoveredPebble?
    private var pendingPingCookie: UInt32?
    private var nextPingCookie: UInt32 = 1
    private var isAutomaticReconnect = false
    private var activeTransferSession: PutBytesTransferSession?
    private var transferContinuation: CheckedContinuation<Void, any Error>?

    public override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "dev.pebble.central"]
        )
        observeSystemTimeChanges()
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

            scanTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else {
                    return
                }
                self?.finishScan()
            }
        }
    }

    public func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        try await waitForBluetooth()

        guard connectionContinuation == nil else {
            throw PebbleConnectionError.connectionAlreadyInProgress
        }
        guard let peripheral = discoveredPeripherals[device.id] else {
            throw PebbleConnectionError.deviceNotFound
        }

        centralManager.stopScan()
        pendingDevice = device
        peripheral.delegate = self

        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuation = continuation
            centralManager.connect(peripheral)

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
        guard let peripheral = discoveredPeripherals[device.id] else {
            return
        }
        intentionalDisconnectIdentifiers.insert(device.id)
        reconnectDevice = nil
        stopHealthChecks()
        centralManager.cancelPeripheralConnection(peripheral)
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        try sendFrame(frame, to: peripheral)
    }

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in
            frameContinuation = continuation
        }
    }

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in
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
        try sendFrame(AppReorderCodec.frame(applicationIDs: applicationIDs), to: peripheral)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        guard let peripheral = connectedPeripheral,
              ppogSession != nil else {
            throw PebbleConnectionError.disconnected
        }
        try sendFrame(AppFetchCodec.responseFrame(status: status), to: peripheral)
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
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
            appBankID: appBankID
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
            serialNumber: information.serialNumber
        )
        self.connectedDevice = connectedDevice
        let initialConnectionContinuation = connectionContinuation
        initialConnectionContinuation?.resume(returning: connectedDevice)
        connectionContinuation = nil
        pendingDevice = nil
        connectedPeripheral = peripheral
        reconnectDevice = device
        isAutomaticReconnect = false
        if initialConnectionContinuation == nil {
            eventContinuation?.yield(.deviceUpdated(connectedDevice))
        }
        startHealthChecks(on: peripheral)
    }

    private func failConnection(_ error: PebbleConnectionError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
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
        stopHealthChecks()
        failTransfer(error)
    }

    private func model(from advertisementData: [String: Any]) -> PebbleWatchModel? {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisesPPoG = serviceUUIDs.contains(Self.ppogService)

        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data else {
            return advertisesPPoG ? model(fromName: advertisementData[CBAdvertisementDataLocalNameKey] as? String) : nil
        }

        let bytes = [UInt8](manufacturerData)
        let containsCompanyIdentifier = bytes.count >= 2
            && Self.vendorIdentifiers.contains(UInt16(bytes[0]) | UInt16(bytes[1]) << 8)
        guard containsCompanyIdentifier || advertisesPPoG else {
            return nil
        }

        let payloadOffset = containsCompanyIdentifier ? 2 : 0
        let hardwarePlatformOffset = payloadOffset + 13
        guard bytes.indices.contains(hardwarePlatformOffset) else {
            return model(fromName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        }

        return model(fromHardwarePlatform: bytes[hardwarePlatformOffset])
            ?? model(fromName: advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    }

    private func model(fromHardwarePlatform value: UInt8) -> PebbleWatchModel? {
        PebbleWatchModel(hardwarePlatform: value)
    }

    private func model(fromName name: String?) -> PebbleWatchModel? {
        guard let normalizedName = name?.lowercased() else {
            return nil
        }
        if normalizedName.contains("duo") {
            return .pebble2Duo
        }
        if normalizedName.contains("round 2") {
            return .pebbleRound2
        }
        if normalizedName.contains("time 2") {
            return .pebbleTime2
        }
        return nil
    }

    private func write(_ packet: PPoGPacket, to peripheral: CBPeripheral) throws {
        guard let characteristic = activeWriteCharacteristic else {
            throw PebbleConnectionError.protocolNegotiationFailed
        }

        let bytes = try packet.encoded(for: .one)
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
        for action in actions {
            switch action {
            case .send(let packet):
                try write(packet, to: peripheral)
            case .deliver(let bytes):
                let frames = try frameDecoder.append(bytes)
                for frame in frames {
                    try process(frame, peripheral: peripheral)
                    frameContinuation?.yield(frame)
                }
            case .resetRequired:
                throw PebbleConnectionError.protocolNegotiationFailed
            }
        }
    }

    private func sendFrame(
        _ frame: PebbleProtocolFrame,
        to peripheral: CBPeripheral
    ) throws {
        guard var session = ppogSession else {
            throw PebbleConnectionError.disconnected
        }

        let bytes = try frame.encoded()
        let maximumPacketSize = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let actions = try session.enqueue(bytes, maximumPacketSize: maximumPacketSize)
        ppogSession = session
        try handle(actions, peripheral: peripheral)
        updateAcknowledgementTimeout(for: peripheral)
    }

    private func process(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        if frame.endpoint == PingPongCodec.endpoint {
            try processPingPong(frame, peripheral: peripheral)
            return
        }

        if frame.endpoint == AppFetchCodec.endpoint {
            eventContinuation?.yield(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))
            return
        }

        if frame.endpoint == PutBytesCodec.endpoint, activeTransferSession != nil {
            try processPutBytesResponse(frame, peripheral: peripheral)
            return
        }

        guard frame.endpoint == WatchVersionCodec.endpoint,
              pendingDevice != nil else {
            return
        }
        let information = try WatchVersionCodec.decode(frame)
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
        finishConnection(peripheral: peripheral, information: information)
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
            pendingPingCookie = nil
            pongTimeoutTask?.cancel()
            pongTimeoutTask = nil
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

    private func sendHealthCheck(on peripheral: CBPeripheral) {
        guard pendingPingCookie == nil else {
            return
        }
        let cookie = nextPingCookie
        nextPingCookie &+= 1
        do {
            try sendFrame(PingPongCodec.frame(for: .ping(cookie: cookie)), to: peripheral)
            pendingPingCookie = cookie
            pongTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, self?.pendingPingCookie == cookie else {
                    return
                }
                self?.centralManager.cancelPeripheralConnection(peripheral)
            }
        } catch {
            centralManager.cancelPeripheralConnection(peripheral)
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
        connectedPeripheral = nil
        connectedDevice = nil
        latestBatteryLevel = nil
        ppogSession = nil
        frameDecoder = PebbleProtocolFrameDecoder()
        pendingGattWrites.removeAll()
        acknowledgementTimeoutTask?.cancel()
        acknowledgementTimeoutTask = nil
        stopHealthChecks()
        failTransfer(PebbleConnectionError.disconnected)
    }

    private func reconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard centralManager.state == .poweredOn else {
            eventContinuation?.yield(.disconnected(.bluetoothUnavailable))
            return
        }
        pendingDevice = device
        isAutomaticReconnect = true
        peripheral.delegate = self
        eventContinuation?.yield(.reconnecting(deviceID: device.id))
        centralManager.connect(peripheral)
    }

    private func scheduleReconnect(to device: DiscoveredPebble, using peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else {
                return
            }
            self?.reconnect(to: device, using: peripheral)
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
            centralManager.cancelPeripheralConnection(peripheral)
            failConnection(.connectionTimedOut)
        }
    }
}

public enum PutBytesClientError: Error, Equatable, Sendable {
    case transferAlreadyInProgress
}

extension CoreBluetoothPebbleClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = bluetoothWaiters
        bluetoothWaiters.removeAll()

        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
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
            failConnection(.bluetoothUnavailable)
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
        peripheral.discoverServices([Self.ppogService, Self.batteryService])
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
            isAutomaticReconnect = false
            return
        }
        if (wasConnected || isAutomaticReconnect), let deviceToReconnect {
            reconnect(to: deviceToReconnect, using: peripheral)
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
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.ppogService }) else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        peripheral.discoverCharacteristics(
            [Self.ppogNotifyCharacteristic, Self.ppogWriteCharacteristic],
            for: service
        )

        if let batteryService = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) {
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

        guard error == nil,
              let characteristics = service.characteristics,
              let notifyCharacteristic = characteristics.first(where: { $0.uuid == Self.ppogNotifyCharacteristic }),
              let writeCharacteristic = characteristics.first(where: { $0.uuid == Self.ppogWriteCharacteristic }) else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        activeWriteCharacteristic = writeCharacteristic
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        if characteristic.uuid == Self.batteryLevelCharacteristic {
            return
        }

        guard characteristic.uuid == Self.ppogNotifyCharacteristic,
              error == nil,
              characteristic.isNotifying else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        do {
            try write(.resetRequest(sequence: 0, version: .one), to: peripheral)
        } catch {
            failConnection(.protocolNegotiationFailed)
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

        guard characteristic.uuid == Self.ppogNotifyCharacteristic,
              error == nil,
              let value = characteristic.value else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        do {
            let packet = try PPoGPacket(decoding: [UInt8](value))
            switch packet {
            case .resetRequest(_, let version):
                try write(
                    .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                    to: peripheral
                )
                if version == .zero {
                    return
                }
            case .resetComplete(_, let receiveWindow, let transmitWindow):
                try write(
                    .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                    to: peripheral
                )
                ppogSession = PPoGSession(
                    receiveWindow: min(Int(transmitWindow), 25),
                    transmitWindow: min(Int(receiveWindow), 25)
                )
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
            failConnection(.protocolNegotiationFailed)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = activeWriteCharacteristic else {
            return
        }
        flushWrites(to: peripheral, characteristic: characteristic)
    }
}
