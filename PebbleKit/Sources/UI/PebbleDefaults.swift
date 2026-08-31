import API
// The conformances at the bottom are on public types, so the protocol they
// conform to has to be as visible as they are.
public import Defaults
import Foundation

/// Every preference the app stores, in one place and with its type.
///
/// These were string literals repeated across the files that read and wrote
/// them, which is how the same preference came to be read two different ways
/// and how the watchface identifiers ended up converted to and from strings by
/// hand at each site.
extension Defaults.Keys {
    /// Where the application catalog is fetched from.
    static let catalogSource = Key<String?>("appCatalogSource")

    /// Firmware fetched from PebbleOS and waiting to be installed.
    static let downloadedFirmware = Key<DownloadedFirmware?>("downloadedFirmware")

    /// The places the watch shows weather for, and the unit their temperatures
    /// are sent in — the watch stores a number with no unit attached.
    static let weatherPlaces = Key<[WeatherPlace]>("weatherPlaces", default: [])
    static let weatherUsesFahrenheit = Key<Bool>(
        "weatherUsesFahrenheit",
        default: Locale.current.measurementSystem == .us
    )

    /// The watch's own settings as this phone last set them, so a watch that
    /// connects can be brought back to what the reader chose.
    static let watchSettings = Key<[String: Bool]>("watchSettings", default: [:])
    static let activitySettings = Key<PebbleActivitySettings>(
        "activitySettings",
        default: PebbleActivitySettings()
    )
    static let heartRateSettings = Key<PebbleHeartRateSettings>(
        "heartRateSettings",
        default: PebbleHeartRateSettings()
    )
    static let reminderAppEnabled = Key<Bool>("reminderAppEnabled", default: true)
    /// The short replies the watch offers. Empty means the reader has not
    /// chosen any yet, not that they want none.
    static let cannedReplies = Key<[String]>("cannedReplies", default: [])

    /// Whether notifications raised by installed watch apps are delivered.
    static let companionNotificationsEnabled = Key<Bool>("companionNotificationsEnabled", default: true)

    /// Whether the welcome screen has been dismissed.
    static let hasCompletedOnboarding = Key<Bool>("hasCompletedPebbleOnboarding", default: false)

    /// The watchface currently running on the watch.
    static let activeWatchfaceID = Key<UUID?>("activeWatchfaceID")

    /// Watchfaces the user marked as favourites.
    static let favoriteWatchfaceIDs = Key<[UUID]>("favoriteWatchfaceIDs", default: [])

    /// When health samples were last written to HealthKit.
    static let healthKitLastExportDate = Key<Date>("healthKitLastExportDate", default: .distantPast)
}

extension DownloadedFirmware: Defaults.Serializable {}
extension WeatherPlace: Defaults.Serializable {}
extension PebbleActivitySettings: Defaults.Serializable {}
extension PebbleHeartRateSettings: Defaults.Serializable {}
