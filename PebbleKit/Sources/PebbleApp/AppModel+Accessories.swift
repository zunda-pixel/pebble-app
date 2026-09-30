#if os(iOS)
public import PebbleProtocol
import SwiftUI
#else
import PebbleProtocol
#endif

extension AppModel {
    /// Opens the scanning client's radio, on iOS once AccessorySetupKit's
    /// session is up and any migration picker is showing: a central already
    /// open stops that picker appearing, and there is no second chance in the
    /// same launch.
    func openRadio() async {
        #if os(iOS)
        await setUpAccessories()
        #endif
        scannerClient.startBluetooth()
    }
}

#if os(iOS)
extension AppModel {
    func setUpAccessories() async {
        await watchAccessories.offerMigration(of: watches.saved)
        offerAccessoriesNotYetAdded()
    }

    /// An accessory the system has for this app and the app has no record of —
    /// added through the picker, then never connected — is offered the way a
    /// bonded watch reaching the app by itself is elsewhere.
    ///
    /// Replaces the list rather than merging into it. On iOS nothing else fills
    /// it — `noteWatchThatReconnectedItself` is reached only from the
    /// phone-hosted GATT server, which iOS does not start — and a merge would go
    /// on offering an accessory the reader has removed in Settings.
    func offerAccessoriesNotYetAdded() {
        let savedIDs = Set(watches.saved.map(\.id))
        let connectedIDs = Set(connections.map(\.watch.id))
        watches.unknownBonded = watchAccessories.accessories
            .filter { !savedIDs.contains($0.id) && !connectedIDs.contains($0.id) }
            .map { UnknownBondedWatch(id: $0.id, name: $0.name) }
    }

    /// Shows the system's picker, and returns the watch chosen in it for the
    /// caller to connect to. Nil when none was, with the reason in
    /// `watches.feedback` if the picker could not be shown.
    public func chooseWatch() async -> UnknownBondedWatch? {
        await setUpAccessories()
        do {
            let chosen = try await watchAccessories.choose()
            offerAccessoriesNotYetAdded()
            watches.feedback = nil
            return chosen.first.map { UnknownBondedWatch(id: $0.id, name: $0.name) }
        } catch WatchAccessories.PickerError.alreadyShowing {
            return nil
        } catch {
            watches.feedback = .failure("The system's accessory picker could not be shown.")
            return nil
        }
    }

    public func notificationForwarding(watchID: WatchID) -> NotificationForwarding? {
        watchAccessories.forwarding[watchID]
    }

    public func refreshNotificationForwarding(watchID: WatchID) async {
        await setUpAccessories()
        await watchAccessories.refreshForwarding(watchID)
    }

    public func requestNotificationForwarding(watchID: WatchID) async {
        await watchAccessories.requestForwarding(watchID)
    }

    public func openNotificationForwardingSettings(watchID: WatchID) async {
        await watchAccessories.presentForwardingSettings(watchID)
    }

    /// False when the system kept the accessory, with the reason in
    /// `watches.feedback`.
    func forgetAccessory(_ watchID: WatchID) async -> Bool {
        do {
            try await watchAccessories.forget(watchID)
            return true
        } catch {
            watches.feedback = .failure(
                "The watch was forgotten here, but iOS still lists it. Remove it in Settings > Bluetooth."
            )
            return false
        }
    }
}
#endif
