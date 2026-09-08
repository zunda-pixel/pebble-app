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
    static let watchSettings = Key<[String: Bool]>("watchSettings", default: [:])
    static let activitySettings = Key<ActivitySettings>(
        "activitySettings",
        default: ActivitySettings()
    )
    static let heartRateSettings = Key<HeartRateSettings>(
        "heartRateSettings",
        default: HeartRateSettings()
    )
    static let reminderAppEnabled = Key<Bool>("reminderAppEnabled", default: true)

    static let companionNotificationsEnabled = Key<Bool>("companionNotificationsEnabled", default: true)

    /// Off until the reader asks for it: the recognizer's model is a download,
    /// and dictation the watch cannot serve is better refused than half-served.
    static let voiceTranscriptionEnabled = Key<Bool>("voiceTranscriptionEnabled", default: false)

    /// A new key rather than the launch-time welcome's: an install that saw that
    /// one has still never been asked for anything.
    static let hasCompletedWatchSetup = Key<Bool>("hasCompletedPebbleWatchSetup", default: false)

    static let activeWatchfaceID = Key<UUID?>("activeWatchfaceID")

    static let healthKitLastExportDate = Key<Date>("healthKitLastExportDate", default: .distantPast)
}

extension DownloadedFirmware: Defaults.Serializable {}
extension WeatherPlace: Defaults.Serializable {}
extension ActivitySettings: Defaults.Serializable {}
extension HeartRateSettings: Defaults.Serializable {}
