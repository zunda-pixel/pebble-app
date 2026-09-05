public import PebbleProtocol
import PebbleTransport
import AsyncOperations
import Foundation
import SwiftUI

extension AppModel {
    public func loadSavedWatches() async {
        do {
            savedWatches = try await watchStore.allWatches()
            watchManagementFeedback = nil
            let library = applicationLibrary
            let states = await savedWatches
                .filter { installedApplicationIDsByWatch[$0.id] == nil }
                .asyncMap(numberOfConcurrentTasks: 4) { watch in
                    let ids = (try? await library.synchronizedApplicationIDs(watchID: watch.id)) ?? []
                    return (watch.id, Set(ids))
                }
            for (watchID, ids) in states {
                installedApplicationIDsByWatch[watchID] = ids
            }
        } catch {
            watchManagementFeedback = .failure("Saved watches could not be loaded.")
        }
    }

    /// A watch that has been set up does not advertise and does not wait to be
    /// found: it reconnects and subscribes to the phone's protocol service.
    func observeWatchesReconnectingThemselves() {
        PebbleGattServer.shared.onUnclaimedWatch = { [weak self] centralID in
            guard let self else { return }
            // A watch is a central to the phone-hosted service, and iOS gives the
            // same identifier for it in both roles.
            Task { await self.noteWatchThatReconnectedItself(watchID: WatchID(centralID)) }
        }
    }

    func noteWatchThatReconnectedItself(watchID: WatchID) async {
        if let watch = savedWatches.first(where: { $0.id == watchID }) {
            await PebbleDiagnostics.shared.record(
                category: "connection",
                message: "\(watch.name) reconnected on its own; opening a link to it"
            )
            await connect(to: watch)
            return
        }
        // Connecting to a watch the app has no record of is the reader's call, so it
        // is only offered.
        guard !unknownBondedWatches.contains(where: { $0.id == watchID }) else {
            return
        }
        let watch = UnknownBondedWatch(id: watchID, name: await bondedWatchName(watchID: watchID))
        unknownBondedWatches.append(watch)
        await PebbleDiagnostics.shared.record(
            category: "connection",
            message: "\(watch.name) is paired with this phone but not added; offering it"
        )
    }

    public func connect(to watch: UnknownBondedWatch) async {
        await connect(to: provisionalWatch(id: watch.id, name: watch.name))
    }

    private func bondedWatchName(watchID: WatchID) async -> String {
        let hint = provisionalWatch(id: watchID, name: "Pebble")
        let retrieved = try? await scannerClient.retrieveKnownWatches([hint])
        return retrieved?.first { $0.id == watchID }?.name ?? hint.name
    }

    // Only the identifier and the name are real; the version the watch reports
    // on connecting replaces the rest.
    private func provisionalWatch(id: WatchID, name: String) -> DiscoveredWatch {
        DiscoveredWatch(id: id, name: name, model: .pebble2Duo, signalStrength: 0)
    }

    public func setAutomaticallyConnects(_ enabled: Bool, watchID: WatchID) async {
        do {
            savedWatches = try await watchStore.setAutomaticallyConnects(enabled, watchID: watchID)
            watchManagementFeedback = nil
        } catch {
            watchManagementFeedback = .failure("The automatic connection preference could not be saved.")
        }
    }

    public func forgetWatch(id: WatchID) async {
        // A successful reconnect would otherwise re-save the forgotten entry.
        if let connection = connections.first(where: { $0.watch.id == id }) {
            await close(connection)
        }
        do {
            savedWatches = try await watchStore.remove(watchID: id)
            installedApplicationIDsByWatch[id] = nil
            connectionFailures[id] = nil
            watchResetFeedback[id] = nil
            watchManagementFeedback = nil
        } catch {
            watchManagementFeedback = .failure("The watch could not be forgotten.")
        }
    }

    public func disconnect(watchID: WatchID) async {
        guard let connection = connections.first(where: { $0.watch.id == watchID }) else {
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
                device: connectedWatch,
                applications: watchApplications + watchfaces
            )
        } catch {
            applicationLibraryFeedback = .failure("The diagnostic report could not be created.")
        }
    }

    // The watch reboots without answering, so the connection is closed locally.
    public func resetWatch(_ kind: PebbleResetKind, watchID: WatchID? = nil) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            watchManagementFeedback = .failure("Connect the watch before resetting it.")
            return
        }
        let device = connection.watch
        do {
            try await connection.client.send(ResetCodec.frame(kind))
            if kind == .factoryReset {
                try? await applicationLibrary.setSynchronizedApplicationIDs([], watchID: device.id)
                installedApplicationIDsByWatch[device.id] = []
            }
            await PebbleDiagnostics.shared.record(
                .warning,
                category: "reset",
                message: "Sent reset command \(kind) to the watch"
            )
            watchManagementFeedback = nil
            await close(connection)
            let message: LocalizedStringKey = switch kind {
            case .restart: "The watch is restarting."
            case .recoveryFirmware: "The watch is restarting into recovery firmware."
            case .factoryReset:
                "The watch is erasing itself. It has forgotten this device, so it cannot reconnect until it is forgotten here too."
            }
            // Progress, not success: the watch has gone away to do it, and the
            // only news afterwards is the link returning.
            watchResetFeedback[device.id] = .progress(message)
        } catch {
            watchResetFeedback[device.id] = nil
            watchManagementFeedback = .failure("The reset command could not be sent.")
        }
    }

    func recordConnectedWatch(_ device: ConnectedWatch) async {
        // A watch that is talking again has finished restarting, whoever opened
        // the link. Every way back in passes through here.
        watchResetFeedback[device.id] = nil
        noteFirmwareUpdateFinished(on: device)
        do {
            savedWatches = try await watchStore.record(device)
            watchManagementFeedback = nil
        } catch {
            watchManagementFeedback = .failure("The watch connection history could not be saved.")
        }
    }
}
