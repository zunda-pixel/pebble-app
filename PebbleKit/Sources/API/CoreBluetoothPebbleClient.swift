public import CoreBluetooth
public import Foundation

@MainActor
public final class CoreBluetoothPebbleClient: NSObject, PebbleClient {
    private static var ppogService = CBUUID(string: "40000000-328E-0FBB-C642-1AA6699BDADA")
    private static var ppogNotifyCharacteristic = CBUUID(string: "40000001-328E-0FBB-C642-1AA6699BDADA")
    private static var ppogWriteCharacteristic = CBUUID(string: "40000003-328E-0FBB-C642-1AA6699BDADA")
    private static var vendorIdentifiers: Set<UInt16> = [0x0154, 0x0EEA]

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var scanResults: [String: DiscoveredPebble] = [:]
    private var bluetoothWaiters: [CheckedContinuation<Void, any Error>] = []
    private var scanContinuation: CheckedContinuation<[DiscoveredPebble], any Error>?
    private var connectionContinuation: CheckedContinuation<PebbleDevice, any Error>?
    private var pendingDevice: DiscoveredPebble?
    private var activeWriteCharacteristic: CBCharacteristic?
    private var scanTimeoutTask: Task<Void, Never>?
    private var connectionTimeoutTask: Task<Void, Never>?

    public override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "dev.pebble.central"]
        )
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
        centralManager.cancelPeripheralConnection(peripheral)
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

    private func finishConnection(peripheral: CBPeripheral) {
        guard let device = pendingDevice else {
            failConnection(.protocolNegotiationFailed)
            return
        }

        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionContinuation?.resume(
            returning: PebbleDevice(
                id: peripheral.identifier.uuidString,
                name: device.name,
                model: device.model,
                firmwareVersion: nil,
                batteryLevel: nil
            )
        )
        connectionContinuation = nil
        pendingDevice = nil
    }

    private func failConnection(_ error: PebbleConnectionError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        connectionContinuation?.resume(throwing: error)
        connectionContinuation = nil
        pendingDevice = nil
        activeWriteCharacteristic = nil
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
        switch value {
        case 15:
            .pebble2Duo
        case 13, 16, 17, 18, 243, 244, 247, 249:
            .pebbleTime2
        case 19, 20, 21:
            .pebbleRound2
        default:
            nil
        }
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
        peripheral.writeValue(Data(bytes), for: characteristic, type: .withResponse)
    }
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
        peripheral.discoverServices([Self.ppogService])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        failConnection(.connectionFailed)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        if pendingDevice?.id == peripheral.identifier.uuidString {
            failConnection(.disconnected)
        }
        activeWriteCharacteristic = nil
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
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
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
            case .resetComplete:
                try write(
                    .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                    to: peripheral
                )
                finishConnection(peripheral: peripheral)
            case .data, .acknowledgement:
                return
            }
        } catch {
            failConnection(.protocolNegotiationFailed)
        }
    }
}
