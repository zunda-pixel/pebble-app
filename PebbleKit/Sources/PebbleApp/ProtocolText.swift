public import SwiftUI
public import PebbleProtocol

/// The protocol layer has no string catalog of its own: it names its cases for
/// the logs and leaves the sentence to this layer.
public extension WatchConnectionError {
    /// See above: the case is named for the logs, the sentence belongs here.
    var message: LocalizedStringKey {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is turned off or temporarily unavailable."
        case .bluetoothUnsupported:
            "Bluetooth Low Energy is not supported on this device."
        case .permissionDenied:
            Self.permissionDeniedMessage
        case .scanAlreadyInProgress:
            "A watch scan is already in progress."
        case .watchNotFound:
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
        case .handshakeKeptFailing:
            "This watch connects but does not answer. Restart it, or forget it here and add it again."
        case .pairingRemovedByWatch:
            "The connection failed: the watch has thrown away its pairing with this device. A Pebble keeps one, so pairing it with another phone or computer does this. Forget the watch in the system Bluetooth settings, then pair it again here."
        case .watchServicesOutOfDate:
            "This iPhone is holding an out-of-date copy of the watch's Bluetooth services. Forget the watch in Settings > Bluetooth, then add it again here."
        case .watchFirmwareTooOldForiOS:
            "This watch's firmware is too old to connect to the iPhone app. Update its firmware from the Pebble app on a Mac, then connect it here again."
        }
    }

    private static var permissionDeniedMessage: LocalizedStringKey {
        #if os(macOS)
        return "Bluetooth access is not allowed. Allow it in System Settings."
        #else
        return "Bluetooth access is not allowed. Allow it in Settings."
        #endif
    }
}

public extension BlobDBClientError {
    /// `localizedDescription` on a Swift error enum reads "The operation couldn't
    /// be completed. (PebbleTransport.BlobDBClientError error 1.)", which told a
    /// reader whose reminder had been refused nothing at all.
    var message: LocalizedStringKey {
        switch self {
        case .operationAlreadyInProgress:
            "The watch is still busy with the last change."
        case .rejected(let status):
            status.message
        }
    }
}

public extension BlobDBStatus {
    var message: LocalizedStringKey {
        switch self {
        case .success:
            "The watch accepted it."
        case .generalFailure:
            "The watch could not store it."
        case .invalidOperation:
            "The watch does not allow that change."
        case .invalidDatabaseID:
            "This firmware has nowhere to keep it."
        case .invalidData:
            "The watch could not read what was sent."
        case .keyDoesNotExist:
            "The watch no longer has it."
        case .databaseFull:
            "There is no room left on the watch."
        case .dataStale:
            "The watch already has a newer copy."
        case .notSupported:
            "This firmware does not support it."
        case .locked:
            "The watch is using it right now."
        case .tryLater:
            "The watch is busy. Try again in a moment."
        }
    }
}

/// What to tell the reader when a watch turns something down. Errors from the
/// protocol layer are named for the logs; the screens need a sentence, and the
/// one Foundation writes for a Swift error names the type and a number.
func refusalReason(for error: any Error) -> LocalizedStringKey {
    if let error = error as? BlobDBClientError {
        return error.message
    }
    if let error = error as? WatchConnectionError {
        return error.message
    }
    return "The watch did not accept it."
}

/// For a failure that may as well be a file or the network as the watch:
/// the protocol layer's errors get their sentence, and anything else keeps
/// what Foundation says, rather than `refusalReason`'s "the watch did not
/// accept it" about a download that never reached the watch.
func failureReason(for error: any Error) -> Text {
    if let error = error as? BlobDBClientError {
        return Text(error.message)
    }
    if let error = error as? WatchConnectionError {
        return Text(error.message)
    }
    return Text(verbatim: error.localizedDescription)
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
        // Bare, because they sit in a section headed "Music": the prefix they
        // used to carry was doing that section's job on a flat list.
        case .musicShowVolumeControls: "Volume Controls"
        case .musicShowProgressBar: "Progress Bar"
        case .musicShowAlbumArt: "Album Art"
        case .unitsDistance: "Distance"
        case .unitsWind: "Wind Speed"
        case .textSize: "Text Size"
        case .backlightPreset: "Backlight Brightness"
        case .backlightTimeout: "Backlight Duration"
        case .backlightIntensity: "Backlight Level"
        case .backlightTouchWake: "Backlight on Touch"
        case .backlightDynamicMode: "Dynamic Backlight"
        case .backlightColor: "Backlight Color"
        // "Manual" is the firmware's own word for the hand-operated switch,
        // as against the calendar and the schedules.
        case .quietTimeManual: "Manual"
        case .quietTimeSmart: "During Calendar Events"
        case .quietTimeAutoDismiss: "Auto-Dismiss Notifications"
        case .quietTimeWeekdayScheduleEnabled, .quietTimeWeekendScheduleEnabled: "Scheduled"
        case .quietTimeWeekdaySchedule, .quietTimeWeekendSchedule: "Schedule"
        }
    }

    /// What each value of a choice is called, in the firmware's own order so
    /// that the index is the number sent.
    ///
    /// Empty for a switch, which has a title and no options.
    var optionTitles: [LocalizedStringKey] {
        switch self {
        case .unitsDistance: ["Kilometers", "Miles"]
        // The first follows whatever distance is set to, which is what
        // `UnitsWind_FromDistance` means and what the watch does with it.
        case .unitsWind: ["Match Distance", "km/h", "mph"]
        case .textSize: ["Small", "Medium", "Large", "Extra Large"]
        // `BacklightPreset`. "Advanced" is the watch's own word for "the
        // backlight settings were set by hand"; called "Custom" here because
        // there is nothing advanced about it from this side. It is offered so
        // that a watch on it is not shown as being on something else, and it
        // is what the row falls back to whenever the underlying values have
        // drifted from every preset.
        case .backlightPreset: ["Brightest", "Standard", "Battery Saver", "Custom"]
        // Said in seconds because the watch says seconds; the wire is
        // milliseconds and the reader never sees one.
        case .backlightTimeout: ["3 Seconds", "5 Seconds", "8 Seconds"]
        // `BacklightTouchWake`, in the firmware's order.
        case .backlightTouchWake: ["Double Tap", "Tap", "Off"]
        // `BacklightDynamicMode`, in the firmware's order.
        case .backlightDynamicMode: ["Off", "Bright", "Standard", "Dim"]
        default: []
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

public extension NotificationVibePattern {
    var title: LocalizedStringKey {
        switch self {
        case .silent: "No Buzz"
        case .standard: "Standard"
        case .pulses: "Pulses"
        case .double: "Double"
        case .triple: "Triple"
        case .bloom: "Bloom"
        case .pips: "Pips"
        case .ole: "Olé"
        case .sos: "SOS"
        case .ohhhOh: "Ohhh, Oh"
        case .five: "Five"
        case .two: "Two"
        }
    }
}

public extension TimelineIcon {
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

public extension HeartRateInterval {
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
