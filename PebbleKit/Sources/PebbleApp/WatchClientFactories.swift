public import PebbleProtocol
import PebbleTransport

@MainActor
public func makeDefaultPebbleClient() -> any WatchClient {
    CoreBluetoothWatchClient()
}

// The restoration identifier has to be stable and unique per watch, or iOS
// hands one client another's restored state.
@MainActor
public func makeDefaultWatchClientFactory() -> @MainActor (WatchID) -> any WatchClient {
    { watchID in
        CoreBluetoothWatchClient(restoreIdentifier: "dev.pebble.central.watch.\(watchID)")
    }
}

#if os(macOS)
@MainActor
public func makeQEMUWatchClient() -> any WatchClient {
    QEMUWatchClient()
}
#endif
