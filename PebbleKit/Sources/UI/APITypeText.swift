public import SwiftUI
public import API

/// The protocol layer has no string catalog of its own: it names its cases for
/// the logs and leaves the sentence to this layer.
public extension PebbleConnectionError {
    /// See above: the case is named for the logs, the sentence belongs here.
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

public extension WatchSetting {
    var title: LocalizedStringKey {
        switch self {
        case .clock24Hour: "24-Hour Clock"
        case .standbyMode: "Standby Mode"
        case .backlight: "Backlight"
        case .backlightAmbientSensor: "Backlight Only in the Dark"
        case .backlightMotion: "Backlight on Wrist Flick"
        case .timelineQuickView: "Timeline Quick View"
        case .menuScrollWrapAround: "Menus Wrap Around"
        case .musicShowVolumeControls: "Music: Volume Controls"
        case .musicShowProgressBar: "Music: Progress Bar"
        }
    }
}

public extension NotificationAppMuteState {
    var title: LocalizedStringKey {
        switch self {
        case .never: "Never"
        case .always: "Always"
        case .weekdays: "Weekdays"
        case .weekends: "Weekends"
        }
    }
}

public extension PebbleTimelineIcon {
    var title: LocalizedStringKey {
        switch self {
        case .generic: "Notification"
        case .sms: "Message"
        case .email: "Mail"
        case .calendar: "Calendar"
        case .reminder: "Reminder"
        case .alarmClock: "Alarm"
        case .duringPhoneCall: "Phone Call"
        case .missedCall: "Missed Call"
        case .musicEvent: "Music"
        case .newsEvent: "News"
        case .payBill: "Payment"
        case .scheduledEvent: "Event"
        case .warning: "Warning"
        case .question: "Question"
        case .flag: "Flag"
        default: "Notification"
        }
    }
}

public extension PebbleHeartRateInterval {
    var title: LocalizedStringKey {
        switch self {
        case .everyTenMinutes: "Every 10 Minutes"
        case .everyThirtyMinutes: "Every 30 Minutes"
        case .everyHour: "Every Hour"
        case .off: "Off"
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
        case .failed: "Stopped"
        }
    }
}
