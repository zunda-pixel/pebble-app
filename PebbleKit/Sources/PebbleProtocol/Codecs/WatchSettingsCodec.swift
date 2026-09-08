public import Foundation
import MemberwiseInit

/// What one setting holds, and how wide it is on the wire.
///
/// The width is the firmware's own: every key below reaches
/// `prv_pref_set(key, &value, sizeof(value))` in `src/fw/shell/normal/prefs.c`
/// with a `bool`, a `uint8_t` or a `uint32_t` behind it, and this says which.
///
/// A wrong width is not caught for us. `settings_blob_db_insert` writes the
/// bytes into the settings file as they arrive, so a four-byte pref given one
/// byte is read back as that byte plus three of whatever was beside it.
public enum WatchSettingKind: Equatable, Sendable {
    case boolean
    /// One of `0..<count`, numbered as the firmware numbers it.
    ///
    /// Out of range is not sent: `system_theme_set_content_size` logs
    /// "Ignoring attempt to set content size to invalid size" and keeps what it
    /// had, so a value past the end is a write that silently does nothing.
    case choice(count: Int)
    /// A length of time in milliseconds, four bytes wide, and one of the
    /// lengths the watch itself offers rather than any number at all.
    ///
    /// The watch's own display settings list `{ 3000, 5000, 8000 }` with the
    /// labels "3 Seconds", "5 Seconds", "8 Seconds"
    /// (`src/fw/apps/system/settings/display.c`). Offering a free number here
    /// would let the reader pick one the watch has no name for.
    case duration(milliseconds: [Int])
    /// Any number in a range, one byte wide.
    ///
    /// Unlike a choice, the numbers are not names for anything, so they are not
    /// offered one at a time — `optionRawValues` lists them all and nothing
    /// should build a picker out of that.
    case number(range: ClosedRange<Int>)

    /// How many bytes the value takes, which is what the firmware stores it as.
    public var width: Int {
        switch self {
        case .boolean, .choice, .number: 1
        case .duration: 4
        }
    }
}

/// The firmware accepts writes for a whitelisted set of keys only
/// (`settings_blob_db.c`); anything else is refused.
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
    /// `UnitsDistance`: 0 kilometres, 1 miles.
    case unitsDistance
    /// `UnitsWind`: 0 follow the distance unit, 1 km/h, 2 mph.
    case unitsWind
    /// `PreferredContentSize`: 0 small … 3 extra large. Named for what the
    /// watch calls it on screen rather than for the key, which says "style".
    case textSize = "textStyle"
    /// `BacklightPreset`: 0 max brightness, 1 standard, 2 battery saver,
    /// 3 advanced.
    ///
    /// Not a setting of its own on the watch, however much it looks like one:
    /// see `BacklightPreset` below for what writing it has to mean.
    case backlightPreset = "lightPreset"
    /// How long the backlight stays on, in milliseconds.
    case backlightTimeout = "lightTimeoutMs"
    /// How bright the backlight is, 1 to 100.
    case backlightIntensity = "lightIntensity"
    /// `BacklightTouchWake`: 0 double tap, 1 tap, 2 off. Only a watch with a
    /// touchscreen does anything with it.
    case backlightTouchWake = "lightTouch"
    /// `BacklightDynamicMode`: 0 off, 1 bright, 2 standard, 3 dim.
    case backlightDynamicMode = "lightDynamicMode"

    public var kind: WatchSettingKind {
        switch self {
        case .unitsDistance: .choice(count: 2)
        case .unitsWind: .choice(count: 3)
        case .textSize: .choice(count: 4)
        case .backlightPreset: .choice(count: 4)
        case .backlightTouchWake: .choice(count: 3)
        case .backlightDynamicMode: .choice(count: 4)
        case .backlightTimeout: .duration(milliseconds: [3_000, 5_000, 8_000])
        // `BACKLIGHT_INTENSITY_MIN` to `BACKLIGHT_INTENSITY_MAX`. Zero is not
        // in it: `prv_set_s_backlight_intensity` treats it as invalid and
        // writes the default back, so a backlight is turned off with
        // `lightEnabled` and not by winding this down.
        case .backlightIntensity: .number(range: 1...100)
        default: .boolean
        }
    }

    /// Whether the watch may not have this setting at all.
    ///
    /// `lightDynamicMode` sits behind `CONFIG_DYNAMIC_BACKLIGHT` in both
    /// `prefs.c` and the sync whitelist, so a watch built without it answers
    /// the write with `E_INVALID_OPERATION` — a logged warning on the watch and
    /// nothing else (`settings_blob_db.c:332`). That is a fact about the model,
    /// not a failure the reader did anything about, so it is not said out loud.
    public var mayBeAbsent: Bool { self == .backlightDynamicMode }

    /// Whether this setting gets a row for a watch on this board.
    ///
    /// The two conditional rows are conditional differently. `lightTouch` is a
    /// pref every board keeps and every whitelist takes; the watch's own
    /// settings app just hides the row behind `CONFIG_TOUCH`, because a wake
    /// gesture for a screen that cannot feel one does nothing. This app hides
    /// it for the same reason. `lightDynamicMode` is out of the whitelist
    /// itself on a board built without it, so its row would not even reach
    /// the pref.
    ///
    /// A nil board — a watch this app cannot place — hides both: a row that
    /// might do nothing is worse than no row.
    public func isOffered(on board: WatchBoard?) -> Bool {
        switch self {
        case .backlightTouchWake: board?.hasTouch == true
        case .backlightDynamicMode: board?.hasDynamicBacklight == true
        default: true
        }
    }

    /// What the watch has before anybody changes it, from the initialisers in
    /// `prefs.c`.
    public var defaultRawValue: Int {
        switch self {
        case .clock24Hour, .menuScrollWrapAround, .musicShowProgressBar: 0
        case .standbyMode, .backlight, .backlightAmbientSensor, .backlightMotion,
             .timelineQuickView, .musicShowVolumeControls: 1
        // `s_units_distance = UnitsDistance_Miles`.
        case .unitsDistance: 1
        // `s_units_wind = UnitsWind_FromDistance`.
        case .unitsWind: 0
        // `s_text_style = PreferredContentSizeDefault`, which is medium.
        case .textSize: 1
        // `s_backlight_preset = BacklightPreset_Standard`.
        case .backlightPreset: 1
        // `DEFAULT_BACKLIGHT_TIMEOUT_MS` in `src/fw/shell/prefs.h`.
        case .backlightTimeout: 3_000
        // `shell_prefs_init` sets this to the Standard preset's own intensity,
        // "so fresh devices report Mode: Standard" as its comment puts it, and
        // not to `BACKLIGHT_INTENSITY_DEFAULT`, which is the value a *rejected*
        // write falls back to.
        case .backlightIntensity: 50
        // `s_backlight_touch_wake = BacklightTouchWake_DoubleTap`.
        case .backlightTouchWake: 0
        // `s_backlight_dynamic_mode = BacklightDynamicMode_Standard`.
        case .backlightDynamicMode: 2
        }
    }

    public var defaultValue: Bool { defaultRawValue != 0 }

    /// Every value this setting can hold, in the order they should be offered.
    ///
    /// Not the same as the option's position: a choice is numbered from zero,
    /// but a duration's value is the number of milliseconds, so a picker has to
    /// carry the value rather than the index it sits at.
    public var optionRawValues: [Int] {
        switch kind {
        case .boolean: [0, 1]
        case .choice(let count): Array(0..<count)
        case .duration(let milliseconds): milliseconds
        case .number(let range): Array(range)
        }
    }

    /// Whether a value is one this setting can hold, so that neither this app
    /// nor the watch is asked to store something meaningless.
    public func accepts(rawValue: Int) -> Bool {
        switch kind {
        case .boolean: (0...1).contains(rawValue)
        case .choice(let count): (0..<count).contains(rawValue)
        case .duration(let milliseconds): milliseconds.contains(rawValue)
        case .number(let range): range.contains(rawValue)
        }
    }
}

/// A backlight preset, which is a name for seven other settings rather than a
/// setting of its own.
///
/// This matters because writing `lightPreset` on its own does nothing a reader
/// can see. The watch's own settings screen calls `backlight_set_preset`
/// (`src/fw/shell/normal/prefs.c:1459`), which writes the preset key *and* the
/// seven values it stands for. A phone write goes down a different road:
/// `prefs_private_handle_blob_db_event` calls the per-pref handler, and
/// `lightPreset`'s handler assigns the global and touches nothing else. So the
/// brightness, the timeout, the sensor and the wrist flick all stay as they
/// were, and `backlight_get_preset` — which compares them against the preset
/// and answers `Advanced` on any mismatch — stops reporting the preset at all.
/// The firmware's own comment on that function names this exact case:
/// "they can drift independently (e.g. via phone sync)".
///
/// So a preset is written by writing what it means (#115).
public enum BacklightPreset {
    public static let maxBrightness = 0
    public static let standard = 1
    public static let batterySaver = 2
    /// The watch's word for "these were set by hand". It stands for no set of
    /// values, which is why choosing it writes only the preset key — the same
    /// early return `backlight_set_preset` takes.
    public static let advanced = 3

    /// The values a concrete preset stands for, from `s_backlight_preset_settings`
    /// in `prefs.c`. Nil for `advanced`, which stands for none.
    public static func settings(for preset: Int) -> [WatchSetting: Int]? {
        switch preset {
        // Every concrete preset has the backlight on: the only off switch lives
        // in the Advanced submenu, which these hide.
        case maxBrightness: [
            .backlight: 1, .backlightAmbientSensor: 1, .backlightIntensity: 100,
            .backlightTimeout: 5_000, .backlightMotion: 1, .backlightTouchWake: 0,
            .backlightDynamicMode: 0,
        ]
        case standard: [
            .backlight: 1, .backlightAmbientSensor: 1, .backlightIntensity: 50,
            .backlightTimeout: 3_000, .backlightMotion: 1, .backlightTouchWake: 0,
            .backlightDynamicMode: 2,
        ]
        case batterySaver: [
            .backlight: 1, .backlightAmbientSensor: 1, .backlightIntensity: 25,
            .backlightTimeout: 3_000, .backlightMotion: 1, .backlightTouchWake: 0,
            .backlightDynamicMode: 3,
        ]
        default: nil
        }
    }

    /// The preset the watch would report for a set of values, worked out the
    /// way `backlight_get_preset` works it out.
    ///
    /// Shown rather than the number last written, so that turning the
    /// brightness down by hand reads as "Custom" here as it does on the wrist,
    /// instead of leaving this screen claiming a preset the watch has left.
    ///
    /// The board says which settings take part. A watch whose dynamic
    /// backlight was compiled out never compares it — its value here is
    /// whatever default was never written anywhere, so letting it disagree
    /// would report Advanced on every such watch for ever. A watch that *has*
    /// it compares it the way its own `backlight_get_preset` does, or the
    /// wrist would say Advanced while this screen still claimed Standard.
    /// A nil board is read as the cautious one: not compared.
    public static func reported(
        by value: (WatchSetting) -> Int,
        on board: WatchBoard? = nil
    ) -> Int {
        let stored = value(.backlightPreset)
        guard let settings = settings(for: stored) else { return advanced }
        let compared = settings.filter {
            !$0.key.mayBeAbsent || $0.key.isOffered(on: board)
        }
        return compared.allSatisfy { value($0.key) == $0.value } ? stored : advanced
    }
}

public enum WatchSettingsCodec {
    /// The settings database. Every watch this app can drive has one, and takes
    /// these writes.
    ///
    /// This used to say that a watch not advertising `settingsSync` has no such
    /// database and refuses the write, which had the direction backwards and
    /// would have sent the next reader to gate these writes on a bit the watch
    /// never sets. `settings_sync_support` is the **phone's** claim to the
    /// watch: `settings_blob_db_phone_supports_sync` in PebbleOS's
    /// `src/fw/services/blob_db/settings_blob_db.c` reads it out of the cached
    /// capabilities of the connected phone, and `prefs_sync.c` starts a sync
    /// when the phone reports it. Measured on a watch in the emulator, which
    /// clears bit 23 in its own version response and takes these writes anyway.
    ///
    /// What the bit does gate is the other direction — `blob_db_sync_db` at
    /// `settings_blob_db.c:263` — which is why this app claims it: without the
    /// claim the watch never pushes its own settings back, and a switch flicked
    /// on the wrist stayed on the wrist. See
    /// `PhoneVersionCodec.supportedCapabilities`.
    public static var databaseID: UInt8 { 0x0C }

    /// The key carries its terminator: the firmware accepts the name with or
    /// without one, and sending it matches what the watch itself writes.
    public static func key(for setting: WatchSetting) -> [UInt8] {
        Array(setting.rawValue.utf8) + [0]
    }

    public static func insertFrame(
        _ setting: WatchSetting,
        rawValue: Int,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: setting),
            // As many bytes as the firmware's own variable, little-endian the
            // way an ARM struct is written: a four-byte pref given one byte is
            // read as three bytes of whatever was next to it.
            value: (0..<setting.kind.width).map {
                UInt8(truncatingIfNeeded: rawValue >> (8 * $0))
            },
            token: token
        )
    }

    /// One record the watch pushed back, where this app has a switch for it.
    ///
    /// Nil for a key this app does not model, which is most of them: the
    /// firmware's `s_syncable_settings` and `s_syncable_notif_prefs` in
    /// `src/fw/services/blob_db/settings_blob_db.c` list some seventy keys
    /// between them, and all nine of this app's are in the first list. The rest
    /// are settings only the watch offers — `lightTimeoutMs`, `language`, the
    /// quick-launch buttons, the do-not-disturb schedules — and several are not
    /// booleans at all, so there is nowhere on this side to put them.
    ///
    /// Nil too for a value that is not one byte, rather than reading the first
    /// byte of something that was never one — `lightTimeoutMs` is four, and its
    /// first byte is not a small number that means anything.
    public static func decodeRecord(key: [UInt8], value: [UInt8]) -> (WatchSetting, Int)? {
        // The watch may send the name with its terminator or without it, the
        // same way the firmware accepts both from the phone.
        let name = String(decoding: key.prefix { $0 != 0 }, as: UTF8.self)
        guard let setting = WatchSetting(rawValue: name),
              value.count == setting.kind.width else { return nil }
        // A boolean is anything non-zero, the way C reads one; the others have
        // to be a value the setting has, or this app would show a picker with
        // nothing selected and write the nonsense back to the other watch.
        let rawValue = switch setting.kind {
        case .boolean: value[0] == 0 ? 0 : 1
        case .choice, .number: Int(value[0])
        case .duration: value.reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        guard setting.accepts(rawValue: rawValue) else { return nil }
        return (setting, rawValue)
    }
}

/// The firmware keeps this as one packed record and takes it whole: sent
/// with a height of zero, the watch has a wearer with no height.
@MemberwiseInit(.public)
public struct ActivitySettings: Codable, Equatable, Sendable {
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

/// The whole of `HRMonitoringInterval`, numbered as the firmware numbers it.
/// The raw value is acted on as it stands, so a value the watch has never
/// heard of is not refused, it is obeyed as something else.
public enum HeartRateInterval: UInt8, CaseIterable, Codable, Sendable {
    case everyTenMinutes = 0
    case everyThirtyMinutes = 1
    case everyHour = 2
    case off = 3

    /// A value stored under the app's own earlier numbering reads back as
    /// whatever the firmware means by that number, rather than failing the whole
    /// record.
    public init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(UInt8.self)
        self = Self(rawValue: rawValue) ?? .everyTenMinutes
    }
}

@MemberwiseInit(.public)
public struct HeartRateSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool = true
    public var interval: HeartRateInterval = .everyTenMinutes
    public var isEnabledDuringActivity: Bool = true

    /// `enabled` gates only what an app may ask for (`health_service.c`); the
    /// sampling loop consults the interval alone (`activity.c`), so turning the
    /// reading off has to be written into both.
    public func encoded() -> [UInt8] {
        let measured = isEnabled ? interval : .off
        return [isEnabled ? 1 : 0, measured.rawValue, isEnabledDuringActivity ? 1 : 0]
    }
}

public enum HealthSettingsCodec {
    public static var databaseID: UInt8 { 0x07 }
    public static var activityKey: String { "activityPreferences" }
    public static var heartRateKey: String { "hrmPreferences" }

    public static func insertFrame(
        _ settings: ActivitySettings,
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
        _ settings: HeartRateSettings,
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

@MemberwiseInit(.public)
public struct WatchHealthDay: Equatable, Sendable {
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
    public static func movementValue(for day: WatchHealthDay) -> [UInt8] {
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
    public static func sleepValue(for day: WatchHealthDay) -> [UInt8] {
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

    public static func movementFrame(for day: WatchHealthDay, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(movementKey(weekday: day.weekday).utf8),
            value: movementValue(for: day),
            token: token
        )
    }

    public static func sleepFrame(for day: WatchHealthDay, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: Array(sleepKey(weekday: day.weekday).utf8),
            value: sleepValue(for: day),
            token: token
        )
    }
}

public enum PebbleReminderAppState: UInt8, Codable, Equatable, Sendable {
    case notEnabled = 0
    case notConfigured = 1
    case enabled = 2
}

public extension WeatherCodec {
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
