import PebbleProtocol
public import CoreBluetooth

extension CoreBluetoothWatchClient: CBPeripheralDelegate {
    /// The watch publishes its protocol service once the link is encrypted,
    /// which invalidates iOS's cached service list. This is the signal that a
    /// fresh discovery will actually return it.
    public func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        guard pendingWatch?.id == peripheral.watchID
            || connectedPeripheral?.identifier == peripheral.identifier else {
            return
        }
        Task { [tag = clientTag, uuids = invalidatedServices.map(\.uuid.uuidString)] in
            await DiagnosticLog.shared.record(
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
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "[\(tag)] discovered services [\(uuids.joined(separator: ","))]"
            )
        }

        // A watch that is not bonded yet exposes only this service, so the protocol
        // one is looked for again once pairing finishes.
        if link.setup.pairing == .unknown {
            if let pairingService = services.first(where: { $0.uuid == Self.pairingService }) {
                link.setup.noteCheckingPairing()
                Task { [tag = clientTag] in
                    await DiagnosticLog.shared.record(
                        category: "pairing",
                        message: "[\(tag)] asking the pairing service what it has"
                    )
                }
                peripheral.discoverCharacteristics(
                    [
                        Self.connectivityCharacteristic,
                        Self.pairingTriggerCharacteristic,
                        Self.connectionParametersCharacteristic,
                    ],
                    for: pairingService
                )
            } else {
                Task { [tag = clientTag] in
                    await DiagnosticLog.shared.record(
                        category: "pairing",
                        message: "[\(tag)] no pairing service; taking the link as bonded"
                    )
                }
                link.setup.noteNoPairingService()
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
        } else if Self.servesTheProtocolItself {
            // The watch expects the phone to host the service and connects to it as a
            // GATT client. It inspects the phone right after connecting and does not come
            // back for a second look.
            startForwardTransport(on: peripheral, because: "the watch hosts none")
        } else {
            // An unbonded watch publishes its own once the link is encrypted, and
            // `didModifyServices` says when; giving up here would refuse every new watch.
            Task { [tag = clientTag] in
                await DiagnosticLog.shared.record(
                    category: "pairing",
                    message: "[\(tag)] no protocol service yet; waiting for the watch to publish it"
                )
            }
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

            link.activeBatteryCharacteristic = characteristic
            peripheral.readValue(for: characteristic)
            if characteristic.properties.contains(.notify)
                || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            return
        }

        if service.uuid == Self.pairingService {
            Task { [
                tag = clientTag,
                uuids = (service.characteristics ?? []).map(\.uuid.uuidString),
                described = error.map { String(describing: $0) } ?? "none"
            ] in
                await DiagnosticLog.shared.record(
                    category: "pairing",
                    message: "[\(tag)] the pairing service has [\(uuids.joined(separator: ","))] error=\(described)"
                )
            }
            guard error == nil,
                  let characteristics = service.characteristics,
                  let connectivity = characteristics.first(where: { $0.uuid == Self.connectivityCharacteristic }) else {
                Task { [tag = clientTag] in
                    await DiagnosticLog.shared.record(
                        .warning,
                        category: "pairing",
                        message: "[\(tag)] no connectivity characteristic; taking the link as bonded"
                    )
                }
                link.setup.noteNoPairingService()
                startProtocolIfReady(on: peripheral)
                return
            }
            link.activePairingTriggerCharacteristic = characteristics.first {
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
            // Reading this is what asks for the bond, and the answer arrives at
            // `handleConnectivity`. Nothing between the two is the watch not
            // answering, or the system not asking.
            Task { [tag = clientTag] in
                await DiagnosticLog.shared.record(
                    category: "pairing",
                    message: "[\(tag)] reading the watch's pairing state"
                )
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
        link.activeWriteCharacteristic = writeCharacteristic
        link.ppogNotifyCharacteristicToSubscribe = notifyCharacteristic
        startProtocolIfReady(on: peripheral)
    }

    // Subscribing before the link is known to be bonded fails on a watch that is
    // not paired yet.
    private func startProtocolIfReady(on peripheral: CBPeripheral) {
        guard link.setup.mayStartProtocol, link.ppogSession == nil else {
            return
        }
        switch link.setup.transport {
        case .reversed:
            guard let notifyCharacteristic = link.ppogNotifyCharacteristicToSubscribe else {
                return
            }
            link.ppogNotifyCharacteristicToSubscribe = nil
            peripheral.setNotifyValue(true, for: notifyCharacteristic)
        case .forward:
            guard GATTServer.shared.isSubscribed(centralID: peripheral.identifier.uuidString) else {
                waitForTheWatchToSubscribe(on: peripheral)
                return
            }
            handleForwardTransportReady(on: peripheral)
        }
    }

    /// Whether the phone may host the protocol service when the watch's own is
    /// unusable. The iOS app pairs through AccessorySetupKit, which refuses to
    /// let a process that uses it make a `CBPeripheralManager` (issue #47).
    static var servesTheProtocolItself: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    private func startForwardTransport(on peripheral: CBPeripheral, because reason: String) {
        guard Self.servesTheProtocolItself else {
            giveUpOnOutOfDateServices(peripheral, because: reason)
            return
        }
        guard link.setup.hostTransportOnPhone() else {
            return
        }
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "[\(tag)] serving the protocol from the phone: \(reason)"
            )
        }
        GATTServer.shared.start()
        GATTServer.shared.register(
            centralID: peripheral.identifier.uuidString,
            onReceive: { [weak self] bytes in
                self?.handleIncomingProtocolBytes(bytes, from: peripheral)
            },
            onSubscribe: { [weak self] in
                self?.handleForwardTransportReady(on: peripheral)
            },
            onUnsubscribe: { [weak self] in
                guard let self, self.link.setup.transport == .forward else { return }
                self.abortLink(peripheral, error: .disconnected, step: "hosting the transport: the watch unsubscribed")
            }
        )
    }

    /// What is left on iOS when the watch's own service cannot be used: iOS is
    /// holding the services as they were, and only forgetting the watch in the
    /// system's settings throws that copy away. Another attempt would find the
    /// same copy, so a reconnect in progress stops too.
    private func giveUpOnOutOfDateServices(_ peripheral: CBPeripheral, because reason: String) {
        guard !link.hasGivenUpOnOutOfDateServices else { return }
        link.hasGivenUpOnOutOfDateServices = true
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
                .error,
                category: "pairing",
                message: "[\(tag)] iOS's copy of the watch's services is out of date: \(reason)"
            )
        }
        guard connectionContinuation == nil else {
            failConnection(.watchServicesOutOfDate)
            return
        }
        reconnects.stop()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pendingWatch = nil
        reconnects.expectDisconnect(of: peripheral.watchID)
        eventContinuation?.yield(.disconnected(.watchServicesOutOfDate))
        cancelLink(peripheral, reason: "iOS holds the watch's services out of date")
    }

    /// Torn down rather than merely deselected: the registration's unsubscribe
    /// callback would otherwise drop the link, and its receive callback would
    /// feed packets in from a transport no longer in use.
    private func endForwardTransport(on peripheral: CBPeripheral) {
        guard link.ppogSession == nil, link.setup.handTransportBackToWatch() else {
            return
        }
        GATTServer.shared.unregister(centralID: peripheral.identifier.uuidString)
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
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
        guard !link.hasRepublishedForThisLink, link.subscriptionWatchdog == nil else {
            return
        }
        link.subscriptionWatchdog = Task { [weak self, tag = clientTag] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.link.subscriptionWatchdog = nil
            let centralID = peripheral.identifier.uuidString
            guard self.link.setup.transport == .forward,
                  self.link.ppogSession == nil,
                  !GATTServer.shared.isSubscribed(centralID: centralID) else {
                return
            }
            self.link.hasRepublishedForThisLink = true
            await DiagnosticLog.shared.record(
                .warning,
                category: "pairing",
                message: "[\(tag)] the watch has not subscribed to the phone's service; publishing it again"
            )
            GATTServer.shared.republish(chasing: centralID)
        }
    }

    private func handleForwardTransportReady(on peripheral: CBPeripheral) {
        guard link.setup.transport == .forward, link.ppogSession == nil, link.setup.mayStartProtocol else {
            return
        }
        // On this transport the watch sends the reset request once it has subscribed;
        // starting one from here too leaves both sides mid-handshake. One it sent
        // before this side could answer is still answered.
        let steps = link.setup.stepsToOpenTheSession(askingIfNeeded: false)
        guard !steps.isEmpty else {
            Task { [tag = clientTag] in
                await DiagnosticLog.shared.record(
                    category: "pairing",
                    message: "[\(tag)] waiting for the watch to open the session"
                )
            }
            return
        }
        do {
            try perform(steps, answering: nil, on: peripheral)
        } catch {
            abortLink(peripheral, error: .protocolNegotiationFailed, step: "opening the session")
        }
    }

    private func handleConnectivity(_ bytes: [UInt8], on peripheral: CBPeripheral) {
        guard let status = ConnectivityStatus(decoding: bytes) else {
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
            await DiagnosticLog.shared.record(
                category: "pairing",
                message: "[\(clientTag)] connectivity paired=\(status.isPaired) encrypted=\(status.isEncrypted)"
                    + " connected=\(status.isConnected) bondedGateway=\(status.hasBondedGateway)"
                    + " pinsWithoutSlaveSecurity=\(status.supportsPinningWithoutSlaveSecurity)"
                    + " error=\(status.pairingError)"
            )
        }
        switch link.setup.apply(status) {
        case .wait:
            return
        case .ready(let wasPairing):
            link.pairingTimeoutTask?.cancel()
            link.pairingTimeoutTask = nil
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
        if let trigger = link.activePairingTriggerCharacteristic {
            peripheral.writeValue(
                Data(PairingTrigger.value()),
                for: trigger,
                type: trigger.properties.contains(.write) ? .withResponse : .withoutResponse
            )
        }
        // Pairing waits on the reader accepting a prompt.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        link.pairingTimeoutTask?.cancel()
        link.pairingTimeoutTask = Task { [weak self] in
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
            // A characteristic that will not turn on is the same problem as one
            // that was never there: iOS is holding handles from the database the
            // watch had last time, and a recovery firmware's database is not
            // that one — hence "The handle is invalid". The watch has meanwhile
            // subscribed to the phone's service, so hosting the transport is a
            // way through rather than a reason to drop a watch that is talking.
            startForwardTransport(
                on: peripheral,
                because: "the watch's own characteristic would not subscribe"
                    + " (\(error?.localizedDescription ?? "it did not turn on"))"
            )
            return
        }

        do {
            // Answering what the watch already asked for, if it got in first,
            // rather than asking again into a watch that is waiting for us.
            try perform(
                link.setup.stepsToOpenTheSession(askingIfNeeded: true),
                answering: nil,
                on: peripheral
            )
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
                // Reading this needs the link encrypted, so a refusal here is
                // the bond being refused rather than a characteristic problem.
                Task { [tag = clientTag, described = error.map { String(describing: $0) } ?? "it was empty"] in
                    await DiagnosticLog.shared.record(
                        .warning,
                        category: "pairing",
                        message: "[\(tag)] the watch's pairing state could not be read: \(described)"
                    )
                }
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
            let steps = link.setup.steps(for: packet, hasSession: link.ppogSession != nil)
            if steps.isEmpty {
                Task { [tag = clientTag] in
                    await DiagnosticLog.shared.record(
                        category: "ppog",
                        message: "[\(tag)] a packet arrived before there was a way to answer it; left alone"
                    )
                }
                return
            }
            try perform(steps, answering: packet, on: peripheral)
        } catch {
            guard link.ppogSession == nil else {
                // A packet that makes no sense is no reason to drop a working
                // link: the transport re-sends whatever went unacknowledged.
                Task { [tag = clientTag, message = error.localizedDescription] in
                    await DiagnosticLog.shared.record(
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

    /// Carries out what `LinkSetup` decided.
    ///
    /// `packet` is the one the steps are answering, and only `.giveToSession`
    /// needs it — a step nothing but `steps(for:hasSession:)` can produce, which
    /// is why the steps that open a handshake may pass none.
    private func perform(
        _ steps: [PPoGStep],
        answering packet: PPoGPacket?,
        on peripheral: CBPeripheral
    ) throws {
        for step in steps {
            switch step {
            case .startSessionOver(let reason):
                abandonSession(on: peripheral, because: reason)

            case .answerReset:
                try write(
                    .resetComplete(sequence: 0, receiveWindow: 25, transmitWindow: 25),
                    to: peripheral
                )

            case .askForReset:
                try write(.resetRequest(sequence: 0, version: .one), to: peripheral)

            case .openSession(let watchReceiveWindow, let watchTransmitWindow):
                try openSession(
                    watchReceiveWindow: watchReceiveWindow,
                    watchTransmitWindow: watchTransmitWindow,
                    on: peripheral
                )

            case .giveToSession:
                guard let packet, var session = link.ppogSession else { return }
                let actions = try session.receive(packet)
                link.ppogSession = session
                try handle(actions, peripheral: peripheral)
                updateAcknowledgementTimeout(for: peripheral)
            }
        }
    }

    /// Opens the transport on the windows the watch offered, and asks it what it
    /// is: the version answer is what turns a session into a connected watch.
    private func openSession(
        watchReceiveWindow: UInt8,
        watchTransmitWindow: UInt8,
        on peripheral: CBPeripheral
    ) throws {
        let session = PPoGSession(
            receiveWindow: min(Int(watchTransmitWindow), 25),
            transmitWindow: min(Int(watchReceiveWindow), 25)
        )
        Task { [
            tag = clientTag,
            watchReceive = watchReceiveWindow,
            watchTransmit = watchTransmitWindow,
            receive = session.receiveWindow,
            transmit = session.transmitWindow,
            packetSize = link.setup.transport == .forward
                ? GATTServer.shared.maximumPacketSize(centralID: peripheral.identifier.uuidString)
                : peripheral.maximumWriteValueLength(for: .withoutResponse)
        ] in
            await DiagnosticLog.shared.record(
                category: "ppog",
                message: "[\(tag)] session open: watch rx=\(watchReceive) tx=\(watchTransmit),"
                    + " ours rx=\(receive) tx=\(transmit), packet size=\(packetSize)"
            )
        }
        link.ppogSession = session
        link.frameDecoder = PebbleProtocolFrameDecoder()
        connectedPeripheral = peripheral
        link.sessionRestartTimeoutTask?.cancel()
        link.sessionRestartTimeoutTask = nil
        handshakePhaseReporter?(.transportOpen)
        try sendFrame(WatchVersionCodec.requestFrame(), to: peripheral)
    }

    // The watch judges a session by this exchange, and data and acknowledgements
    // are far too frequent to log.
    func recordPPoGPacket(_ packet: PPoGPacket, direction: String) {
        let description: String
        switch packet {
        case .resetRequest(let sequence, _): description = "resetRequest seq=\(sequence)"
        case .resetComplete(let sequence, _, _): description = "resetComplete seq=\(sequence)"
        case .acknowledgement, .data: return
        }
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
                category: "ppog",
                message: "[\(tag)] \(direction) \(description)"
            )
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = link.activeWriteCharacteristic else {
            return
        }
        flushWrites(to: peripheral, characteristic: characteristic)
    }
}
