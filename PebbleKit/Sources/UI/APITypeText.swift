public import SwiftUI
import API

/// How the protocol layer's types read on screen. Those types have no string
/// catalog of their own, so they name their cases for the logs and leave the
/// sentence to this file, where it is localized.
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

public extension HealthAnalysisPeriod {
    var title: LocalizedStringKey {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .quarter: "Quarter"
        }
    }
}

public extension FirmwareUpdatePhase {
    var title: LocalizedStringKey {
        switch self {
        case .validated: "Validated"
        case .transferring: "Transferring"
        case .installing: "Installing"
        case .awaitingRestart: "Waiting for restart"
        case .cancelled: "Cancelled"
        }
    }
}
