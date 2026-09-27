import PebbleProtocol
import CoreBluetooth
import Foundation

extension CoreBluetoothWatchClient {
    func write(_ packet: PPoGPacket, to peripheral: CBPeripheral) throws {
        recordPPoGPacket(packet, direction: "out")
        let bytes = try packet.encoded(for: .one)
        if link.setup.transport == .forward {
            guard GATTServer.shared.send(bytes, to: peripheral.identifier.uuidString) else {
                throw WatchConnectionError.protocolNegotiationFailed
            }
            return
        }
        guard let characteristic = link.activeWriteCharacteristic else {
            throw WatchConnectionError.protocolNegotiationFailed
        }
        link.pendingGattWrites.append(Data(bytes))
        flushWrites(to: peripheral, characteristic: characteristic)
    }

    func flushWrites(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        while peripheral.canSendWriteWithoutResponse,
              !link.pendingGattWrites.isEmpty {
            let value = link.pendingGattWrites.removeFirst()
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
                let batch = link.frameDecoder.append(bytes)
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
        guard var session = link.ppogSession else {
            throw WatchConnectionError.disconnected
        }

        Task { await DiagnosticLog.shared.recordFrame(direction: "out", frame: frame) }
        let bytes = try frame.encoded()
        let maximumPacketSize = link.setup.transport == .forward
            ? GATTServer.shared.maximumPacketSize(centralID: peripheral.identifier.uuidString)
            : peripheral.maximumWriteValueLength(for: .withoutResponse)
        let actions = try session.enqueue(bytes, maximumPacketSize: maximumPacketSize)
        link.ppogSession = session
        try handle(actions, peripheral: peripheral)
        updateAcknowledgementTimeout(for: peripheral)
    }

    private func process(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        Task { await DiagnosticLog.shared.recordFrame(direction: "in", frame: frame) }
        if try answer(frame, peripheral: peripheral) { return }
        // A frame the app takes off `frames()` is answered, just not here, and
        // the audio endpoint alone sends fifty a second.
        guard CompanionFrame(endpoint: frame.endpoint) == nil else { return }
        Task { [frame, tag = clientTag] in
            await DiagnosticLog.shared.recordUnansweredFrame(frame, tag: tag)
        }
    }

    /// Whether anything in the app was waiting for this frame. The two
    /// endpoints this link answers itself — its health check and the version
    /// exchange that proves it — come first; everything else is the session's.
    func answer(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        switch frame.endpoint {
        case PebbleProtocolFrame.metaEndpoint:
            // "I do not know that endpoint" is still an answer, and a link the
            // watch is holding up perfectly well should not be dropped for it.
            guard frame.rejectedEndpoint == WatchVersionCodec.endpoint else { return false }
            clearPendingHealthCheck()
            return true

        case WatchVersionCodec.endpoint:
            return try answerWatchVersion(frame, peripheral: peripheral)

        default:
            return try session.answer(frame)
        }
    }

    private func answerWatchVersion(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        // The watch changes what it reports when a language pack is installed,
        // which is how the app finds out.
        if pendingWatch == nil, let watch = connectedWatch {
            clearPendingHealthCheck()
            let information = try WatchVersionCodec.decode(frame)
            var updated = watch
            // The third place that used to copy these across one at a time, and
            // the one that would have been missed by a reader adding a field:
            // `hardwareRevision` was added to the other two and not to this, so
            // a watch that reported one only after a language pack install
            // would have lost it here.
            updated.version = information
            // The platform byte can change under the app — a watch flashed with
            // firmware for another board reports the new one — so the model is
            // resolved again rather than left at what the scan guessed.
            updated.model = WatchModel(hardwarePlatform: information.hardwarePlatform) ?? watch.model
            connectedWatch = updated
            // The health check asks for this once a minute and the answer is
            // almost always the same one; announcing it anyway had the app
            // rewriting its watch library every minute. A session started over
            // is the exception: the app is waiting to hear that the transport
            // works before it re-sends anything.
            if updated != watch || link.isRestartingSession {
                eventContinuation?.yield(.watchUpdated(updated))
            }
            link.isRestartingSession = false
            return true
        }

        guard pendingWatch != nil else { return false }
        let information = try WatchVersionCodec.decode(frame)
        Task { [
            tag = clientTag,
            summary = information.diagnosticSummary,
            recovery = information.isRunningRecoveryFirmware
        ] in
            await DiagnosticLog.shared.record(
                recovery ? .error : .info,
                category: "connection",
                message: "[\(tag)] \(summary)"
                    + (recovery ? " (recovery firmware: only a firmware install will work)" : "")
            )
        }
        try sendFrame(TimeSynchronizationCodec.frame(), to: peripheral)
        finishConnection(peripheral: peripheral, information: information)
        return true
    }

    func updateAcknowledgementTimeout(for peripheral: CBPeripheral) {
        link.acknowledgementTimeoutTask?.cancel()
        link.acknowledgementTimeoutTask = nil

        guard link.ppogSession?.hasPendingAcknowledgements == true else {
            return
        }

        link.acknowledgementTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else {
                return
            }
            self?.retryUnacknowledgedPackets(on: peripheral)
        }
    }

    private func retryUnacknowledgedPackets(on peripheral: CBPeripheral) {
        guard var session = link.ppogSession else {
            return
        }

        do {
            let actions = try session.handleAcknowledgementTimeout()
            link.ppogSession = session
            try handle(actions, peripheral: peripheral)
            updateAcknowledgementTimeout(for: peripheral)
        } catch {
            abortLink(peripheral, error: .connectionTimedOut, step: "resending unacknowledged packets")
        }
    }
}
