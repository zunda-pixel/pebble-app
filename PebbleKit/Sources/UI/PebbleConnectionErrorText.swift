public import SwiftUI
import API

public extension PebbleConnectionError {
    /// What the reader is told when a connection attempt fails.
    ///
    /// The protocol layer has no string catalog, so it only names the case for
    /// the logs; the sentence belongs here, where it is localized.
    var message: LocalizedStringKey {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is turned off or temporarily unavailable."
        case .bluetoothUnsupported:
            "Bluetooth Low Energy is not supported on this device."
        case .permissionDenied:
            "Bluetooth access is not allowed. Enable it in System Settings."
        case .scanAlreadyInProgress:
            "A watch scan is already in progress."
        case .deviceNotFound:
            "The selected watch is no longer available. Scan again."
        case .connectionAlreadyInProgress:
            "Another watch connection is already in progress."
        case .connectionFailed:
            "The watch connection failed. Move the watch closer and try again."
        case .connectionTimedOut:
            "The watch did not respond in time."
        case .protocolNegotiationFailed:
            "The watch does not expose the expected Pebble connection service."
        case .disconnected:
            "The watch disconnected."
        }
    }
}
