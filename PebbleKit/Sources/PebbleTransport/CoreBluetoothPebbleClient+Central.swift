import PebbleProtocol
public import CoreBluetooth

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
