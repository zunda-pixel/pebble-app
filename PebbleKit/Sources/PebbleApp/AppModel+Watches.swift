public import PebbleProtocol
import Defaults
import PebbleTransport
import AsyncOperations
import Foundation
import SwiftUI

extension AppModel {
    public func loadSavedWatches() async {
        do {
            watches.saved = try await watchStore.allWatches()
            watches.feedback = nil
            let library = applicationLibrary
            let states = await watches.saved
                .filter { applications.installedIDsByWatch[$0.id] == nil }
                .asyncMap(numberOfConcurrentTasks: 4) { watch in
                    let ids = (try? await library.synchronizedApplicationIDs(watchID: watch.id)) ?? []
                    return (watch.id, Set(ids))
                }
            for (watchID, ids) in states {
                applications.installedIDsByWatch[watchID] = ids
            }
        } catch {
            watches.feedback = .failure("Saved watches could not be loaded.")
        }
    }

    /// A watch that has been set up does not advertise and does not wait to be
    /// found: it reconnects and subscribes to the phone's protocol service.
    func observeWatchesReconnectingThemselves() {
        GATTServer.shared.onUnclaimedWatch = { [weak self] centralID in
            guard let self else { return }
            // A watch is a central to the phone-hosted service, and iOS gives the
            // same identifier for it in both roles.
            Task { await self.noteWatchThatReconnectedItself(watchID: WatchID(centralID)) }
        }
    }

    func noteWatchThatReconnectedItself(watchID: WatchID) async {
        if let watch = watches.saved.first(where: { $0.id == watchID }) {
            await DiagnosticLog.shared.record(
                category: "connection",
                message: "\(watch.name) reconnected on its own; opening a link to it"
            )
            await connect(to: watch)
            return
        }
        // Connecting to a watch the app has no record of is the reader's call, so it
        // is only offered.
        guard !watches.unknownBonded.contains(where: { $0.id == watchID }) else {
            return
        }
        let watch = UnknownBondedWatch(id: watchID, name: await bondedWatchName(watchID: watchID))
        watches.unknownBonded.append(watch)
        await DiagnosticLog.shared.record(
            category: "connection",
            message: "\(watch.name) is paired with this phone but not added; offering it"
        )
    }

    public func connect(to watch: UnknownBondedWatch) async {
        await connect(to: provisionalTarget(id: watch.id, name: watch.name))
    }

    private func bondedWatchName(watchID: WatchID) async -> String {
        let hint = provisionalTarget(id: watchID, name: "Pebble")
        let retrieved = try? await scannerClient.retrieveKnownWatches([hint])
        return retrieved?.first { $0.id == watchID }?.name ?? hint.name
    }

    // Only the identifier and the name are real, and the target says so: the
    // model stays nil instead of naming some other watch, and the version the
    // watch reports on connecting fills it in.
    private func provisionalTarget(id: WatchID, name: String) -> WatchConnectionTarget {
        WatchConnectionTarget(id: id, name: name, model: nil)
    }

    public func setAutomaticallyConnects(_ enabled: Bool, watchID: WatchID) async {
        do {
            watches.saved = try await watchStore.setAutomaticallyConnects(enabled, watchID: watchID)
            watches.feedback = nil
        } catch {
            watches.feedback = .failure("The automatic connection preference could not be saved.")
        }
    }

    /// False when the watch is still remembered, with the reason in
    /// `watches.feedback`.
    @discardableResult
    public func forgetWatch(id: WatchID) async -> Bool {
        // A successful reconnect would otherwise re-save the forgotten entry.
        connectionAttempts[id] = nil
        if let connection = connections.first(where: { $0.watch.id == id }) {
            await close(connection)
        }
        do {
            watches.saved = try await watchStore.remove(watchID: id)
        } catch {
            watches.feedback = .failure("The watch could not be forgotten.")
            return false
        }
        await forgetEverythingKept(for: id)
        watches.feedback = nil
        #if os(iOS)
        // The watch is gone from the app either way; iOS still listing it is
        // said on the list the reader lands on.
        _ = await forgetAccessory(id)
        offerAccessoriesNotYetAdded()
        #endif
        return true
    }

    /// Everything the app keeps about one watch, on disk and here. Left behind,
    /// the same watch added again inherits it — a firmware update staged for it
    /// before would install itself unasked.
    private func forgetEverythingKept(for id: WatchID) async {
        applications.installedIDsByWatch[id] = nil
        applications.activeWatchfaceIDs[id] = nil
        notifiedFirmwareVersions[id] = nil
        watchesAwaitingApplicationSynchronization.remove(id)
        connectionFailures[id] = nil
        chargeLevels[id] = nil
        chargeNotified.remove(id)
        firmwareCheckedAt = firmwareCheckedAt.filter { !$0.key.hasPrefix("\(id.rawValue)|") }
        firmware.watches[id] = nil
        watches.resetFeedback[id] = nil
        diagnostics.watches[id] = nil
        language.feedback[id] = nil
        let library = applicationLibrary
        let stores = [timelineStore, reminderStore, calendarReminderStore]
        let firmwareUpdates = pendingFirmwareUpdateStore
        let writtenRecords = writtenRecordStore
        do {
            try await firmwareUpdates.clear(watchID: id)
            try await writtenRecords.forget(watchID: id)
            try await library.forgetSynchronizedApplicationIDs(watchID: id)
            for store in stores {
                try await store.forgetWrittenPinIDs(watchID: id)
            }
        } catch {
            // The watch is forgotten either way; what is left is the same
            // records a watch added again would have been given afresh.
            await DiagnosticLog.shared.record(
                .error,
                category: "connection",
                message: "Some records of a forgotten watch could not be removed: \(error)"
            )
        }
    }

    public func disconnect(watchID: WatchID) async {
        connectionAttempts[watchID] = nil
        guard let connection = connections.first(where: { $0.watch.id == watchID }) else {
            return
        }
        await close(connection)
    }

    public func disconnect() async {
        connectionAttempts.removeAll()
        for connection in connections {
            await close(connection)
        }
    }

    func close(_ connection: WatchConnection) async {
        connections.removeAll { $0 === connection }
        await connection.close()
        chargeLevels.removeValue(forKey: connection.watch.id)
        chargeNotified.remove(connection.watch.id)
        clearBusyOperationState(on: connection)
        if activeConnections.isEmpty { musicCoordinator.watchDisconnected() }
        lastConnectionError = nil
    }

    public func prepareDiagnosticReport() async {
        do {
            diagnostics.reportURL = try await DiagnosticLog.shared.exportReport(
                watch: connectedWatch,
                applications: applications.all
            )
            // Nothing to say on success: the Share row appearing is the answer,
            // and this clears whatever an earlier attempt left behind.
            diagnostics.reportFeedback = nil
        } catch {
            // The button for this is on the settings screen. This used to write
            // to `applications.libraryFeedback`, which only the Apps tab shows
            // — so a report that could not be written said so on a screen
            // nobody was looking at, and the settings screen sat there as
            // though nothing had been asked.
            diagnostics.reportFeedback = .failure("The diagnostic report could not be created.")
            // And the earlier report goes with it. Leaving it would keep a
            // Share row offering a file from before whatever went wrong, next
            // to a message saying the report could not be created.
            diagnostics.reportURL = nil
        }
    }

    // The watch reboots without answering, so the connection is closed locally.
    /// The watch is named, never defaulted: "whichever is first" is no answer
    /// for a factory reset.
    public func resetWatch(_ kind: ResetKind, watchID: WatchID) async {
        guard let connection = connection(for: watchID), connection.isConnected else {
            watches.resetFeedback[watchID] = .failure("Connect the watch before resetting it.")
            return
        }
        let watch = connection.watch
        do {
            try await connection.client.send(ResetCodec.frame(kind))
            if kind == .factoryReset {
                try? await applicationLibrary.setSynchronizedApplicationIDs([], watchID: watch.id)
                applications.installedIDsByWatch[watch.id] = []
            }
            await DiagnosticLog.shared.record(
                .warning,
                category: "reset",
                message: "Sent reset command \(kind) to the watch"
            )
            await close(connection)
            let message: LocalizedStringKey = switch kind {
            case .restart: "The watch is restarting."
            case .recoveryFirmware: "The watch is restarting into recovery firmware."
            case .factoryReset:
                "The watch is erasing itself. It has forgotten this device, so it cannot reconnect until it is forgotten here too."
            }
            // Progress, not success: the watch has gone away to do it, and the
            // only news afterwards is the link returning.
            watches.resetFeedback[watch.id] = .progress(message)
        } catch {
            watches.resetFeedback[watch.id] = .failure("The reset command could not be sent.")
        }
    }

    func recordConnectedWatch(_ watch: ConnectedWatch) async {
        // A watch that is talking again has finished restarting, whoever opened
        // the link. Every way back in passes through here.
        watches.resetFeedback[watch.id] = nil
        noteFirmwareUpdateFinished(on: watch)
        do {
            watches.saved = try await watchStore.record(watch)
            // Only this call's own failure is its to clear: it runs on every
            // battery reading, and the list's message may be another watch's.
            if watchHistoryCouldNotBeSaved {
                watchHistoryCouldNotBeSaved = false
                watches.feedback = nil
            }
        } catch {
            watchHistoryCouldNotBeSaved = true
            watches.feedback = .failure("The watch connection history could not be saved.")
        }
    }
}

extension AppModel {
    /// Tells the phone when a watch finishes charging, if the reader asked.
    ///
    /// The shape follows the official app's `BatteryFullyChargedNotification`:
    /// only the *climb* to 100% counts, so a watch that connects already full
    /// says nothing — its first reading has no earlier one to climb from. One
    /// notification per charge: the latch opens again only when the level
    /// falls to 97% or below, so the wobble around full does not ring twice.
    func trackChargeLevel(of watch: ConnectedWatch) async {
        guard let level = watch.batteryLevel else { return }
        let previous = chargeLevels[watch.id]
        chargeLevels[watch.id] = level
        if level <= 97 { chargeNotified.remove(watch.id) }
        guard notifyWhenFullyChargedEnabled,
              level >= 100,
              let previous, previous < 100,
              !chargeNotified.contains(watch.id) else { return }
        chargeNotified.insert(watch.id)
        await localNotifier.post(
            identifier: "fully-charged-\(watch.id.rawValue)",
            title: String(localized: "Fully Charged", bundle: .module),
            body: String(localized: "\(watch.name) is fully charged.", bundle: .module)
        )
    }

    /// Turns the full-charge notification on or off. Asking to be notified is
    /// the one moment the system permission is worth asking for; refused, the
    /// switch falls back rather than promising what cannot arrive.
    public func setNotifyWhenFullyCharged(_ enabled: Bool) async {
        guard enabled else {
            notifyWhenFullyChargedEnabled = false
            Defaults[.notifyWhenFullyCharged] = false
            return
        }
        guard await localNotifier.requestAuthorization() else {
            notifyWhenFullyChargedEnabled = false
            Defaults[.notifyWhenFullyCharged] = false
            phoneAlertsFeedback = .failure(
                "Notifications are turned off for this app in the system settings."
            )
            return
        }
        notifyWhenFullyChargedEnabled = true
        Defaults[.notifyWhenFullyCharged] = true
        phoneAlertsFeedback = nil
    }
}
