import PebbleProtocol
import CoreBluetooth
import Foundation

extension CoreBluetoothWatchClient {
    func startHealthChecks(on peripheral: CBPeripheral) {
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
        guard !session.isTransferring else {
            return
        }
        // A watch being recovered cannot afford a dropped link, and its own
        // timeouts cover the transfer.
        guard connectedWatch?.isRunningRecoveryFirmware != true else {
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

    func clearPendingHealthCheck() {
        isAwaitingHealthCheckReply = false
        healthCheckTimeoutTask?.cancel()
        healthCheckTimeoutTask = nil
    }

    func stopHealthChecks() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        clearPendingHealthCheck()
    }
}
