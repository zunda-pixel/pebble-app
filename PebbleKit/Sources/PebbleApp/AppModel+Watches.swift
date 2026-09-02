public import PebbleProtocol
import PebbleTransport
import AsyncOperations
import Foundation
import SwiftUI

extension AppModel {
    public func loadSavedWatches() async {
        do {
            savedWatches = try await watchLibrary.allWatches()
            watchManagementErrorMessage = nil
            let library = applicationLibrary
            let states = await savedWatches
                .filter { installedApplicationIDsByWatch[$0.id] == nil }
                .asyncMap(numberOfConcurrentTasks: 4) { watch in
                    let ids = (try? await library.synchronizedApplicationIDs(deviceID: watch.id)) ?? []
                    return (watch.id, Set(ids))
                }
            for (watchID, ids) in states {
                installedApplicationIDsByWatch[watchID] = ids
            }
        } catch {
            watchManagementErrorMessage = "Saved watches could not be loaded."
        }
    }

    /// A watch that has been set up does not advertise and does not wait to be
    /// found: it reconnects and subscribes to the phone's protocol service.
    func observeWatchesReconnectingThemselves() {
        PebbleGattServer.shared.onUnclaimedWatch = { [weak self] centralID in
            guard let self else { return }
            Task { await self.noteWatchThatReconnectedItself(centralID: centralID) }
        }
    }

    // The watch and the peripheral share an identifier.
    func noteWatchThatReconnectedItself(centralID: String) async {
        if let watch = savedWatches.first(where: { $0.id == centralID }) {
            await PebbleDiagnostics.shared.record(
                category: "connection",
                message: "\(watch.name) reconnected on its own; opening a link to it"
            )
            await connect(to: watch)
            return
        }
        // Connecting to a watch the app has no record of is the reader's call, so it
        // is only offered.
        guard !unknownBondedWatches.contains(where: { $0.id == centralID }) else {
            return
        }
        let watch = UnknownBondedWatch(id: centralID, name: await bondedWatchName(centralID: centralID))
        unknownBondedWatches.append(watch)
        await PebbleDiagnostics.shared.record(
            category: "connection",
            message: "\(watch.name) is paired with this phone but not added; offering it"
        )
    }

    public func connect(to watch: UnknownBondedWatch) async {
        await connect(to: provisionalDevice(id: watch.id, name: watch.name))
    }

    private func bondedWatchName(centralID: String) async -> String {
        let hint = provisionalDevice(id: centralID, name: "Pebble")
        let retrieved = try? await scannerClient.retrieveKnownDevices([hint])
        return retrieved?.first { $0.id == centralID }?.name ?? hint.name
    }

    // Only the identifier and the name are real; the version the watch reports
    // on connecting replaces the rest.
    private func provisionalDevice(id: String, name: String) -> DiscoveredPebble {
        DiscoveredPebble(id: id, name: name, model: .pebble2Duo, signalStrength: 0)
    }

    public func setAutomaticallyConnects(_ enabled: Bool, watchID: String) async {
        do {
            savedWatches = try await watchLibrary.setAutomaticallyConnects(enabled, watchID: watchID)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The automatic connection preference could not be saved."
        }
    }

    public func forgetWatch(id: String) async {
        // A successful reconnect would otherwise re-save the forgotten entry.
        if let connection = connections.first(where: { $0.device.id == id }) {
            await close(connection)
        }
        do {
            savedWatches = try await watchLibrary.remove(watchID: id)
            installedApplicationIDsByWatch[id] = nil
            connectionFailures[id] = nil
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The watch could not be forgotten."
        }
    }

    public func disconnect(deviceID: String) async {
        guard let connection = connections.first(where: { $0.device.id == deviceID }) else {
            return
        }
        await close(connection)
    }

    public func disconnect() async {
        for connection in connections {
            await close(connection)
        }
    }

    func close(_ connection: WatchConnection) async {
        connections.removeAll { $0 === connection }
        await connection.close()
        clearBusyOperationState(on: connection)
        needsApplicationSynchronization = true
        lastConnectionError = nil
        refreshConnectionState()
    }

    public func prepareDiagnosticReport() async {
        do {
            diagnosticReportURL = try await PebbleDiagnostics.shared.exportReport(
                device: connectedDevice,
                applications: watchApplications + watchfaces
            )
        } catch {
            applicationLibraryErrorMessage = "The diagnostic report could not be created."
        }
    }

    // The watch reboots without answering, so the connection is closed locally.
    public func resetWatch(_ kind: PebbleResetKind, deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            watchManagementErrorMessage = "Connect the watch before resetting it."
            return
        }
        let device = connection.device
        do {
            try await connection.client.send(ResetCodec.frame(kind))
            if kind == .factoryReset {
                try? await applicationLibrary.setSynchronizedApplicationIDs([], deviceID: device.id)
                installedApplicationIDsByWatch[device.id] = []
            }
            await PebbleDiagnostics.shared.record(
                .warning,
                category: "reset",
                message: "Sent reset command \(kind) to the watch"
            )
            watchManagementErrorMessage = nil
            await close(connection)
            watchResetStatusMessage = switch kind {
            case .restart: "The watch is restarting."
            case .recoveryFirmware: "The watch is restarting into recovery firmware."
            case .factoryReset:
                "The watch is erasing itself. It has forgotten this device, so it cannot reconnect until it is forgotten here too."
            }
        } catch {
            watchResetStatusMessage = nil
            watchManagementErrorMessage = "The reset command could not be sent."
        }
    }

    func recordConnectedWatch(_ device: PebbleDevice) async {
        do {
            savedWatches = try await watchLibrary.record(device)
            watchManagementErrorMessage = nil
        } catch {
            watchManagementErrorMessage = "The watch connection history could not be saved."
        }
    }
}
