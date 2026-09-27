import Foundation
import MemberwiseInit

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

/// Blood oxygen (SpO2), which PebbleOS gained over the last two months. The
/// firmware keeps it as three separate prefs rather than one packed record: the
/// on/off bit under `bloodOxygenPreferences`, a during-activity bit under
/// `bloodOxygenActivityPreferences`, and — apart from those — only the
/// measurement interval in `ActivitySpO2Settings` (one byte) under
/// `spo2Preferences`, as its own header comment spells out. So this app writes
/// three keys, not one.
@MemberwiseInit(.public)
public struct BloodOxygenSettings: Codable, Equatable, Sendable {
    /// `s_blood_oxygen_enabled`, off until the wearer asks — the firmware calls
    /// blood-oxygen monitoring opt-in.
    public var isEnabled: Bool = false
    /// `ActivitySpO2Settings.measurement_interval`, an `HRMonitoringInterval`
    /// like the heart rate's. The default is ten minutes, as
    /// `ACTIVITY_SPO2_DEFAULT_PREFERENCES` has it.
    public var interval: HeartRateInterval = .everyTenMinutes
    /// `s_blood_oxygen_activity_enabled`: measure during detected activities too.
    public var isEnabledDuringActivity: Bool = false
}

/// The zone boundaries the watch grades a workout's heart rate against:
/// `HeartRatePreferences` in PebbleOS's `activity.h`, six packed bytes.
///
/// The firmware's handler (`prv_set_s_activity_hr_preferences`) refuses a
/// record whose numbers are out of order — resting over elevated, a zone
/// below the one before it — so `isValid` holds the same two chains and
/// nothing disordered is sent.
@MemberwiseInit(.public)
public struct HeartRateZonePreferences: Codable, Equatable, Sendable {
    /// `ACTIVITY_HEART_RATE_DEFAULT_PREFERENCES`: 70 / 100 / (220 − 30), with
    /// zones at 50%, 70% and 85% of the heart-rate reserve.
    public var restingBPM: Int = 70
    public var elevatedBPM: Int = 100
    public var maximumBPM: Int = 190
    public var zone1BPM: Int = 130
    public var zone2BPM: Int = 154
    public var zone3BPM: Int = 172

    public var isValid: Bool {
        let all = [restingBPM, elevatedBPM, maximumBPM, zone1BPM, zone2BPM, zone3BPM]
        return all.allSatisfy { (1...255).contains($0) }
            && restingBPM <= elevatedBPM && elevatedBPM <= maximumBPM
            && zone1BPM <= zone2BPM && zone2BPM <= zone3BPM
    }

    public func encoded() -> [UInt8] {
        [restingBPM, elevatedBPM, maximumBPM, zone1BPM, zone2BPM, zone3BPM]
            .map { UInt8(clamping: $0) }
    }
}

public enum HealthSettingsCodec {
    public static var databaseID: UInt8 { 0x07 }
    public static var activityKey: String { "activityPreferences" }
    public static var heartRateKey: String { "hrmPreferences" }
    public static var heartRateZonesKey: String { "heartRatePreferences" }
    /// Blood oxygen's on/off bit, its own key on the wire.
    public static var bloodOxygenKey: String { "bloodOxygenPreferences" }
    /// The measurement interval, an `ActivitySpO2Settings` — one byte.
    public static var spo2IntervalKey: String { "spo2Preferences" }
    /// Whether to measure during detected activities.
    public static var bloodOxygenActivityKey: String { "bloodOxygenActivityPreferences" }

    /// Blood oxygen's on/off bit. Its own key on the wire, not folded into the
    /// interval the way heart rate folds its own.
    public static func bloodOxygenEnabledFrame(
        _ isEnabled: Bool,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(bloodOxygenKey.utf8),
            value: [isEnabled ? 1 : 0],
            token: token
        )
    }

    /// The SpO2 measurement interval — an `ActivitySpO2Settings`, which is one
    /// byte holding only the interval.
    public static func spo2IntervalFrame(
        _ interval: HeartRateInterval,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(spo2IntervalKey.utf8),
            value: [interval.rawValue],
            token: token
        )
    }

    /// Whether to measure blood oxygen during detected activities.
    public static func bloodOxygenActivityFrame(
        _ isEnabled: Bool,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(bloodOxygenActivityKey.utf8),
            value: [isEnabled ? 1 : 0],
            token: token
        )
    }

    public static func insertFrame(
        _ preferences: HeartRateZonePreferences,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(heartRateZonesKey.utf8),
            value: preferences.encoded(),
            token: token
        )
    }

    public static func insertFrame(
        _ settings: ActivitySettings,
        token: UInt16
    ) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
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
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: Array(heartRateKey.utf8),
            value: settings.encoded(),
            token: token
        )
    }
}
