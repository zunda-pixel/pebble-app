import PebbleProtocol
import CoreBluetooth
import Foundation

extension CoreBluetoothWatchClient {
    /// Gives up the protocol session while keeping the link that carries it.
    ///
    /// The watch sends a reset mid-session when its acknowledgement timeouts have
    /// run out. What it is asking for is the transport reopened, not the link
    /// dropped — and dropping the link cost a whole reconnect, the bond check and
    /// the several seconds of handshake with it. The work in flight goes either
    /// way, because its tokens belonged to the session that has just ended, and
    /// the app is told the same way a reconnect tells it so that it re-sends
    /// what it has to.
    func abandonSession(on peripheral: CBPeripheral, because reason: String) {
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
                .warning,
                category: "ppog",
                message: "[\(tag)] starting the session over: \(reason)"
            )
        }
        link.ppogSession = nil
        link.frameDecoder = PebbleProtocolFrameDecoder()
        // What the next handshake owes is `LinkSetup.steps(for:hasSession:)`'s
        // to say: it decided to come here, and it decides what follows.
        link.pendingGattWrites.removeAll()
        link.acknowledgementTimeoutTask?.cancel()
        link.acknowledgementTimeoutTask = nil
        // A reply to the check sent over the session that has gone is not coming;
        // the periodic check itself keeps running and is what notices if the
        // restart quietly fails.
        clearPendingHealthCheck()
        failWorkInFlight(.disconnected)
        // Deliberately left alone, unlike `endLink`: the bond, the
        // watch, the health-logging session and the records the watch holds all
        // outlive a transport that was reopened.
        link.isRestartingSession = true
        link.sessionRestartTimeoutTask?.cancel()
        link.sessionRestartTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.link.ppogSession == nil else { return }
            self?.cancelLink(peripheral, reason: "the session was never started over")
        }
        if let watch = connectedWatch {
            eventContinuation?.yield(.reconnecting(watchID: watch.id))
        }
    }

    func clearTransportState() {
        endLink()
        failWorkInFlight(.disconnected)
    }

    /// What both ends of a link reset — a connect that failed and a link that
    /// dropped — so that neither can leave something behind for the next one.
    /// `pendingWatch` is not in it: a dropped link with a reconnect pending is
    /// still waiting for that watch.
    func endLink() {
        link.cancelDeadlines()
        link = LinkState()
        connectedPeripheral = nil
        connectedWatch = nil
        // A session id only means something inside the link that opened it.
        session.forgetDataLoggingSessions()
        stopHealthChecks()
    }

    func failWorkInFlight(_ error: WatchConnectionError) {
        session.failWorkInFlight(error)
    }

    /// Asks iOS for the notification-sharing decision as part of connecting.
    ///
    /// Without this the question is only raised when the watch itself gets round
    /// to asking for ANCS, which is whenever iOS chooses — in practice long
    /// after the reader has left the app, which is where the alert was turning
    /// up. Requiring it here puts the alert on the connect the reader started.
    ///
    /// It is dropped for a watch that has already failed to connect with it,
    /// because with this set a refusal is a failed link: a watch that connects
    /// without notifications is worth more than one that will not connect.
    func connectOptions(for peripheral: CBPeripheral) -> [String: Any]? {
        #if os(iOS)
        guard !refusedNotificationAccess.contains(peripheral.identifier) else {
            requiredNotificationAccess = false
            return nil
        }
        requiredNotificationAccess = true
        return [CBConnectPeripheralOptionRequiresANCS: true]
        #else
        requiredNotificationAccess = false
        return nil
        #endif
    }

    /// Retries without the notification requirement, once per watch.
    ///
    /// Returns whether this attempt is the one being retried, in which case the
    /// caller has nothing left to report: the link is being asked for again.
    func retryWithoutNotificationAccess(_ peripheral: CBPeripheral) -> Bool {
        guard requiredNotificationAccess,
              !refusedNotificationAccess.contains(peripheral.identifier) else {
            return false
        }
        refusedNotificationAccess.insert(peripheral.identifier)
        Task { [tag = clientTag] in
            await DiagnosticLog.shared.record(
                .warning,
                category: "pairing",
                message: "[\(tag)] the link was refused with notification sharing required; asking again without it"
            )
        }
        centralManager.connect(peripheral, options: connectOptions(for: peripheral))
        return true
    }

    func reconnect(to watch: WatchConnectionTarget, using peripheral: CBPeripheral) {
        reconnects.cancelSchedule()
        guard centralManager.state == .poweredOn else {
            eventContinuation?.yield(.reconnecting(watchID: watch.id))
            scheduleReconnect(to: watch, using: peripheral)
            return
        }
        pendingWatch = watch
        reconnects.beginAutomaticAttempt()
        peripheral.delegate = self
        eventContinuation?.yield(.reconnecting(watchID: watch.id))
        // No deadline yet. A watch that is out of range leaves this connect
        // pending, which is CoreBluetooth waiting for it to come back — the
        // right thing. A deadline here cancelled that wait every thirty
        // seconds, counted each cancel as a failed handshake, and gave up on
        // a watch merely left in another room. The handshake's own deadline
        // is armed in `didConnect`, once there is a link to time.
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        centralManager.connect(peripheral, options: connectOptions(for: peripheral))
    }

    /// The deadline for an automatic attempt's handshake, from the link coming
    /// up to the watch's version answer.
    func armReconnectHandshakeDeadline(for peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else {
                return
            }
            // The link is up, so cancelling it comes back as a disconnect,
            // and that is where the failure is counted.
            self?.cancelLink(peripheral, reason: "the reconnect handshake stalled for 30s")
        }
    }

    /// Stops chasing a watch whose links keep dying in the handshake, and says
    /// so: the reader was told "Reconnecting…" for as long as they watched.
    func giveUpReconnecting(to watch: WatchConnectionTarget) {
        let attempts = reconnects.failedHandshakes
        reconnects.stop()
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        pendingWatch = nil
        Task { [tag = clientTag, name = watch.name] in
            await DiagnosticLog.shared.record(
                .error,
                category: "connection",
                message: "[\(tag)] giving up on \(name):"
                    + " \(attempts) links came up and none finished the handshake"
            )
        }
        eventContinuation?.yield(.disconnected(.handshakeKeptFailing))
    }

    func scheduleReconnect(to watch: WatchConnectionTarget, using peripheral: CBPeripheral) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        reconnects.schedule { [weak self] in
            self?.reconnect(to: watch, using: peripheral)
        }
    }

    func resumeReconnectAfterPowerOn() {
        guard let watch = reconnects.watch,
              connectedWatch == nil,
              connectionContinuation == nil else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The pre-power-cycle CBPeripheral may be invalid; look it up again.
            _ = try? await self.retrieveKnownWatches([watch])
            guard self.reconnects.watch?.id == watch.id,
                  self.connectedWatch == nil,
                  self.connectionContinuation == nil,
                  let peripheral = self.discoveredPeripherals[watch.id] else {
                return
            }
            self.reconnect(to: watch, using: peripheral)
        }
    }
}
