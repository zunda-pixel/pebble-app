import PebbleProtocol
public import CoreBluetooth

extension CoreBluetoothWatchClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = bluetoothWaiters
        bluetoothWaiters.removeAll()

        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
            resumeReconnectAfterPowerOn()
        case .unauthorized:
            waiters.forEach { $0.resume(throwing: WatchConnectionError.permissionDenied) }
            loseTheRadio(.permissionDenied)
        case .unsupported:
            waiters.forEach { $0.resume(throwing: WatchConnectionError.bluetoothUnsupported) }
            loseTheRadio(.bluetoothUnsupported)
        case .poweredOff, .resetting:
            waiters.forEach { $0.resume(throwing: WatchConnectionError.bluetoothUnavailable) }
            failScan(.bluetoothUnavailable)
            if connectionContinuation != nil {
                failConnection(.bluetoothUnavailable)
            } else if connectedWatch != nil || reconnects.isAutomatic {
                reconnects.cancelSchedule()
                connectionTimeoutTask?.cancel()
                connectionTimeoutTask = nil
                pendingWatch = nil
                clearTransportState()
                if let watch = reconnects.watch {
                    eventContinuation?.yield(.reconnecting(watchID: watch.id))
                }
            }
        case .unknown:
            bluetoothWaiters.append(contentsOf: waiters)
        @unknown default:
            waiters.forEach { $0.resume(throwing: WatchConnectionError.bluetoothUnavailable) }
        }
    }

    /// Bluetooth refused or absent for good: no reconnect will find the watch,
    /// so none is left chasing it, and a watch the app was showing as
    /// connected — or reconnecting — is said to be gone. `failConnection` alone
    /// cleared the watch without a word, and the disconnect that followed then
    /// found nothing connected to report.
    private func loseTheRadio(_ error: WatchConnectionError) {
        failScan(error)
        let wasShowingAWatch = connectedWatch != nil || reconnects.isAutomatic
        reconnects.stop()
        failConnection(error)
        if wasShowingAWatch {
            eventContinuation?.yield(.disconnected(error))
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let advertised = advertisedWatch(from: advertisementData) else {
            return
        }

        let id = peripheral.watchID
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        discoveredPeripherals[id] = peripheral
        scanResults[id] = DiscoveredWatch(
            id: id,
            name: advertisedName ?? peripheral.name ?? advertised.model?.displayName ?? "Pebble",
            model: advertised.model,
            signalStrength: RSSI.intValue
        )
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pendingWatch?.id == peripheral.watchID else {
            // A connect request that already timed out or was abandoned; do
            // not let it become a session the app does not know about.
            cancelLink(peripheral, reason: "no connect request was waiting for this link")
            return
        }
        link.setup.reset()
        if reconnects.isAutomatic, connectionContinuation == nil {
            reconnects.noteLinkUp()
            armReconnectHandshakeDeadline(for: peripheral)
        }
        // The link is up. Everything from here to the watch's version answer —
        // discovering services, pairing if it is not bonded, opening the PPoG
        // transport — is the handshake, and on a real watch it is where the
        // seconds go.
        handshakePhaseReporter?(.linkOpen)
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
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
        let reason = Self.connectionError(from: error)
        Task { [tag = clientTag, described = error.map { String(describing: $0) } ?? "none"] in
            await DiagnosticLog.shared.record(
                .warning,
                category: "pairing",
                message: "[\(tag)] the connect attempt was refused: \(described)"
            )
        }
        // A bond only the phone still has is not something another attempt, or
        // dropping the notification requirement, can get past.
        guard reason != .pairingRemovedByWatch else {
            reconnects.stop()
            failConnection(reason)
            return
        }
        if retryWithoutNotificationAccess(peripheral) {
            return
        }
        if reconnects.isAutomatic, let watch = reconnects.watch {
            pendingWatch = nil
            scheduleReconnect(to: watch, using: peripheral)
            return
        }
        failConnection(reason)
    }

    /// What CoreBluetooth refused a connect for, where it says something the
    /// reader can act on.
    private static func connectionError(from error: (any Error)?) -> WatchConnectionError {
        guard let error = error as? NSError, error.domain == CBErrorDomain else {
            return .connectionFailed
        }
        return switch CBError.Code(rawValue: error.code) {
        case .peerRemovedPairingInformation: .pairingRemovedByWatch
        case .connectionTimeout: .connectionTimedOut
        default: .connectionFailed
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: (any Error)?
    ) {
        GATTServer.shared.unregister(centralID: peripheral.identifier.uuidString)
        Task { [tag = clientTag, reconnecting = isReconnecting, message = error?.localizedDescription] in
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "[\(tag)] link dropped reconnecting=\(reconnecting) error=\(message ?? "none")"
            )
        }

        let identifier = peripheral.watchID
        let wasConnected = connectedWatch != nil
        let wasIntentional = reconnects.wasExpected(identifier)
        let watchToReconnect = reconnects.watch
        let wasAutomatic = reconnects.isAutomatic
        if pendingWatch?.id == peripheral.watchID, !wasAutomatic {
            failConnection(.disconnected)
        }
        pendingWatch = nil
        clearTransportState()
        if wasIntentional {
            reconnects.stop()
            return
        }
        if (wasConnected || wasAutomatic), let watchToReconnect {
            if wasConnected {
                reconnect(to: watchToReconnect, using: peripheral)
            } else if reconnects.noteDropBeforeSession() {
                // Worth another go, but not forever: only a link that came up
                // and died before a session counts against the budget.
                scheduleReconnect(to: watchToReconnect, using: peripheral)
            } else {
                giveUpReconnecting(to: watchToReconnect)
            }
            return
        }
        if wasConnected {
            eventContinuation?.yield(.disconnected(.disconnected))
        }
    }

#if os(iOS)
    /// The answer to iOS's notification-sharing question, which arrives here and
    /// nowhere else. Without this method CoreBluetooth has nowhere to deliver it
    /// and says so: "could not find a central ... delegateImplemented 0".
    public func centralManager(
        _ central: CBCentralManager,
        didUpdateANCSAuthorizationFor peripheral: CBPeripheral
    ) {
        Task { [tag = clientTag, allowed = peripheral.ancsAuthorized] in
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "[\(tag)] notification sharing \(allowed ? "allowed" : "refused")"
            )
        }
    }
#endif

    public func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in peripherals {
            peripheral.delegate = self
            discoveredPeripherals[peripheral.watchID] = peripheral
        }
    }
}
