import PebbleProtocol
// The conformances at the bottom are on public types, so the protocol they
// conform to has to be as visible as they are.
public import Defaults
import Foundation

extension Defaults.Keys {
    static let downloadedFirmware = Key<DownloadedFirmware?>("downloadedFirmware")

    /// The watch stores a temperature with no unit attached, so the unit the
    /// numbers were converted to has to be remembered here.
    static let weatherPlaces = Key<[WeatherPlace]>("weatherPlaces", default: [])
    static let weatherUsesFahrenheit = Key<Bool>(
        "weatherUsesFahrenheit",
        default: Locale.current.measurementSystem == .us
    )

    /// What every watch setting is set to, keyed by the firmware's own name
    /// and held as the number the firmware holds.
    ///
    /// A second key rather than a changed type on the first. The switches were
    /// stored as `[String: Bool]`, and a `Key` whose type no longer matches the
    /// data on disk decodes as nothing and quietly hands back the default — so
    /// changing it in place would have reset every watch setting the reader had
    /// chosen. `loadWatchSettings` reads the old key once and folds it in.
    static let watchSettingValues = Key<[String: Int]>("watchSettingValues", default: [:])
    /// Off until asked for: a notification nobody opted into is noise, and the
    /// system permission is only requested when this is first turned on.
    static let notifyWhenFullyCharged = Key<Bool>("notifyWhenFullyCharged", default: false)
    /// The weather keeps itself fresh unless the reader says otherwise; off
    /// means only opening the screen or pulling refreshes it.
    static let weatherAutoRefreshEnabled = Key<Bool>("weatherAutoRefreshEnabled", default: true)
    /// How stale a forecast may get before the next chance to refresh takes it.
    /// A floor, not a schedule: the OS decides when the app runs.
    static let weatherRefreshMinutes = Key<Int>("weatherRefreshMinutes", default: 60)
    /// When a refresh last *succeeded*. A failure leaves this alone, which is
    /// what makes the next trigger a retry.
    static let weatherRefreshedAt = Key<Date?>("weatherRefreshedAt", default: nil)
    /// The Weather DB writes and the timeline pins, separately: one is the
    /// watch's weather app, the other is three cards on its timeline, and a
    /// reader may want either without the other.
    static let weatherWritesToWatch = Key<Bool>("weatherWritesToWatch", default: true)
    static let weatherPinsEnabled = Key<Bool>("weatherPinsEnabled", default: false)
    static let notifyAboutFirmwareUpdates = Key<Bool>("notifyAboutFirmwareUpdates", default: false)
    /// The firmware version each watch was last told about, so the same update
    /// is announced once — across launches, not just within one.
    static let notifiedFirmwareVersions = Key<[String: String]>(
        "notifiedFirmwareVersions",
        default: [:]
    )
    /// Quick-launch assignments, keyed by the firmware's own `ql…` names.
    /// Only the buttons the reader has actually set are here; an absent button
    /// keeps the firmware's default rather than being overwritten with it.
    static let quickLaunchAssignments = Key<[String: QuickLaunchAssignment]>(
        "quickLaunchAssignments",
        default: [:]
    )
    static let watchSettings = Key<[String: Bool]>("watchSettings", default: [:])
    static let activitySettings = Key<ActivitySettings>(
        "activitySettings",
        default: ActivitySettings()
    )
    static let heartRateSettings = Key<HeartRateSettings>(
        "heartRateSettings",
        default: HeartRateSettings()
    )
    static let heartRateZonePreferences = Key<HeartRateZonePreferences>(
        "heartRateZonePreferences",
        default: HeartRateZonePreferences()
    )
    static let reminderAppEnabled = Key<Bool>("reminderAppEnabled", default: true)

    /// One row per calendar the reader has touched a switch for; a calendar
    /// with no row is enabled. Carried by name and owner as well as by
    /// identifier, because EventKit reissues identifiers on a full sync.
    static let calendarPreferences = Key<[CalendarPreference]>("calendarPreferences", default: [])
    static let calendarPinsEnabled = Key<Bool>("calendarPinsEnabled", default: true)
    static let calendarIncludesDeclined = Key<Bool>("calendarIncludesDeclined", default: false)
    static let calendarRemindersEnabled = Key<Bool>("calendarRemindersEnabled", default: true)
    static let catalogSourceID = Key<String>("catalogSourceID", default: "pebble")

    static let companionNotificationsEnabled = Key<Bool>("companionNotificationsEnabled", default: true)

    /// Off until the reader asks for it: the recognizer's model is a download,
    /// and dictation the watch cannot serve is better refused than half-served.
    static let voiceTranscriptionEnabled = Key<Bool>("voiceTranscriptionEnabled", default: false)

    /// A new key rather than the launch-time welcome's: an install that saw that
    /// one has still never been asked for anything.
    static let hasCompletedWatchSetup = Key<Bool>("hasCompletedPebbleWatchSetup", default: false)

    static let activeWatchfaceID = Key<UUID?>("activeWatchfaceID")

    /// One cursor per exported type, not one for the batch: a type the reader
    /// had not allowed yet must not be dragged forward by the types they had,
    /// or the data waiting on the permission is stranded behind the cursor
    /// when the permission finally comes.
    static let healthKitLastExportDates = Key<[String: Date]>("healthKitLastExportDates", default: [:])
}

extension DownloadedFirmware: Defaults.Serializable {}
extension WeatherPlace: Defaults.Serializable {}
extension ActivitySettings: Defaults.Serializable {}
extension QuickLaunchAssignment: Defaults.Serializable {}
extension HeartRateSettings: Defaults.Serializable {}
extension HeartRateZonePreferences: Defaults.Serializable {}
extension CalendarPreference: Defaults.Serializable {}
