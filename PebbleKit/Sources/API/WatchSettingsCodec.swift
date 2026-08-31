public import Foundation
import MemberwiseInit

/// How the watch is set up, as the phone can change it.
///
/// The firmware keeps these in its shell preferences and accepts writes for a
/// whitelisted set of keys only (`settings_blob_db.c`). A value is written
/// straight into the preference, so its bytes have to be exactly the size the
/// firmware declared: a boolean is one byte, and a preference sent at the wrong
/// width is refused.
public enum WatchSetting: String, CaseIterable, Codable, Sendable {
    case clock24Hour = "clock24h"
    case standbyMode = "stationaryMode"
    case backlight = "lightEnabled"
    case backlightAmbientSensor = "lightAmbientSensorEnabled"
    case backlightMotion = "lightMotion"
    case timelineQuickView = "timelineQuickViewEnabled"
    case menuScrollWrapAround = "menuScrollWrapAround"
    case musicShowVolumeControls = "musicShowVolumeControls"
    case musicShowProgressBar = "musicShowProgressBar"

    /// Every setting the app offers happens to be a switch. The firmware has
    /// wider ones — backlight timeout, text size — but they are enumerations
    /// whose meaning has to be got exactly right, so they wait.
    public var defaultValue: Bool {
        switch self {
        case .clock24Hour, .menuScrollWrapAround, .musicShowProgressBar:
            false
        case .standbyMode, .backlight, .backlightAmbientSensor, .backlightMotion,
             .timelineQuickView, .musicShowVolumeControls:
            true
        }
    }
}

public enum WatchSettingsCodec {
    /// The settings database. A watch that does not advertise
    /// `settingsSync` has no such database and refuses the write.
    public static var databaseID: UInt8 { 0x0C }

    /// The key carries its terminator: the firmware accepts the name with or
    /// without one, and sending it matches what the watch itself writes.
    public static func key(for setting: WatchSetting) -> [UInt8] {
        Array(setting.rawValue.utf8) + [0]
    }

    public static func insertFrame(
        _ setting: WatchSetting,
        isOn: Bool,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: setting),
            value: [isOn ? 1 : 0],
            token: token
        )
    }
}

/// What the watch's health tracking is set to.
///
/// The firmware stores this as one packed record, so it is written whole: send
/// it with a height of zero and the watch has a wearer with no height. The
/// numbers therefore come from the reader rather than from defaults.
@MemberwiseInit(.public)
public struct PebbleActivitySettings: Codable, Equatable, Sendable {
    public var heightMillimetres: Int16 = 1_700
    /// Weight in decagrams, which is how the firmware counts it: 70 kg is 7000.
    public var weightDecagrams: Int16 = 7_000
    public var isTrackingEnabled: Bool = true
    public var areActivityInsightsEnabled: Bool = true
    public var areSleepInsightsEnabled: Bool = true
    public var ageYears: Int8 = 30
    /// 0 female, 1 male, 2 other, as the firmware numbers them.
    public var gender: Int8 = 2

    public func encoded() -> [UInt8] {
        heightMillimetres.littleEndianBytes
            + weightDecagrams.littleEndianBytes
            + [
                isTrackingEnabled ? 1 : 0,
                areActivityInsightsEnabled ? 1 : 0,
                areSleepInsightsEnabled ? 1 : 0,
                UInt8(bitPattern: ageYears),
                UInt8(bitPattern: gender),
            ]
    }
}

/// How often the watch reads a heart rate.
public enum PebbleHeartRateInterval: UInt8, CaseIterable, Codable, Sendable {
    case off = 0
    case everyTenMinutes = 1
    case everyFiveMinutes = 2
    case continuous = 3
}

@MemberwiseInit(.public)
public struct PebbleHeartRateSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool = true
    public var interval: PebbleHeartRateInterval = .everyTenMinutes
    /// Whether the watch also reads a heart rate during a detected walk or run.
    public var isEnabledDuringActivity: Bool = true

    public func encoded() -> [UInt8] {
        [isEnabled ? 1 : 0, interval.rawValue, isEnabledDuringActivity ? 1 : 0]
    }
}

/// The health preferences, which live in the preferences database rather than
/// with the health history.
public enum HealthSettingsCodec {
    public static var databaseID: UInt8 { 0x07 }
    public static var activityKey: String { "activityPreferences" }
    public static var heartRateKey: String { "hrmPreferences" }

    public static func insertFrame(
        _ settings: PebbleActivitySettings,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(activityKey.utf8),
            value: settings.encoded(),
            token: token
        )
    }

    public static func insertFrame(
        _ settings: PebbleHeartRateSettings,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(heartRateKey.utf8),
            value: settings.encoded(),
            token: token
        )
    }
}

/// A day's activity as the watch's health app reads it back.
///
/// The watch collects its own steps; what the phone adds is the rest of the
/// week — the days the watch did not see, and the typical values it compares
/// today against.
@MemberwiseInit(.public)
public struct PebbleHealthDay: Equatable, Sendable {
    /// Sunday is 0, as the firmware's weekday names are ordered.
    public var weekday: Int
    public var lastProcessed: Date
    public var steps: UInt32
    public var activeKilocalories: UInt32
    public var restingKilocalories: UInt32
    public var distanceMetres: UInt32
    public var activeSeconds: UInt32
    public var sleepSeconds: UInt32
    public var deepSleepSeconds: UInt32
}

public enum HealthStatsCodec {
    /// The health database, which holds a week of days keyed by their name.
    public static var databaseID: UInt8 { 0x0A }

    static let recordVersion: UInt32 = 1
    static let weekdayNames = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
    ]

    /// `<weekday>_movementData`, which is the only shape of key the firmware
    /// accepts: it looks for an underscore and for the day's name.
    public static func movementKey(weekday: Int) -> String {
        "\(weekdayNames[weekday % 7])_movementData"
    }

    public static func sleepKey(weekday: Int) -> String {
        "\(weekdayNames[weekday % 7])_sleepData"
    }

    /// `MovementData`: a version, when the phone last counted, and the day's
    /// totals — all 32-bit and little-endian, and the length has to stay a
    /// multiple of four or the watch refuses it.
    public static func movementValue(for day: PebbleHealthDay) -> [UInt8] {
        recordVersion.littleEndianBytes
            + UInt32(clamping: Int(day.lastProcessed.timeIntervalSince1970)).littleEndianBytes
            + day.steps.littleEndianBytes
            + day.activeKilocalories.littleEndianBytes
            + day.restingKilocalories.littleEndianBytes
            + day.distanceMetres.littleEndianBytes
            + day.activeSeconds.littleEndianBytes
    }

    /// `SleepData`. The four "typical" values are sent as the day's own, which
    /// is what a phone that keeps one week of history can honestly say.
    public static func sleepValue(for day: PebbleHealthDay) -> [UInt8] {
        recordVersion.littleEndianBytes
            + UInt32(clamping: Int(day.lastProcessed.timeIntervalSince1970)).littleEndianBytes
            + day.sleepSeconds.littleEndianBytes
            + day.deepSleepSeconds.littleEndianBytes
            + UInt32(0).littleEndianBytes
            + UInt32(0).littleEndianBytes
            + day.sleepSeconds.littleEndianBytes
            + day.deepSleepSeconds.littleEndianBytes
            + UInt32(0).littleEndianBytes
            + UInt32(0).littleEndianBytes
    }

    public static func movementFrame(for day: PebbleHealthDay, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(movementKey(weekday: day.weekday).utf8),
            value: movementValue(for: day),
            token: token
        )
    }

    public static func sleepFrame(for day: PebbleHealthDay, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(sleepKey(weekday: day.weekday).utf8),
            value: sleepValue(for: day),
            token: token
        )
    }
}

/// Whether the watch shows its Reminders app, which is a preference of that
/// app rather than a setting of the watch.
public enum PebbleReminderAppState: UInt8, Codable, Equatable, Sendable {
    case notEnabled = 0
    case notConfigured = 1
    case enabled = 2
}

public extension WeatherCodec {
    /// The reminders app's own preference, filed in the same database as the
    /// weather app's location order and under its own name.
    static func reminderAppFrame(
        state: PebbleReminderAppState,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: preferencesDatabaseID,
            key: Array("remindersApp".utf8),
            value: [state.rawValue],
            token: token
        )
    }
}
