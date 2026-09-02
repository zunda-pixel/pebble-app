import PebbleProtocol
// The conformances at the bottom are on public types, so the protocol they
// conform to has to be as visible as they are.
public import Defaults
import Foundation

extension Defaults.Keys {
    static let catalogSource = Key<String?>("appCatalogSource")

    static let downloadedFirmware = Key<DownloadedFirmware?>("downloadedFirmware")

    /// The watch stores a temperature with no unit attached, so the unit the
    /// numbers were converted to has to be remembered here.
    static let weatherPlaces = Key<[WeatherPlace]>("weatherPlaces", default: [])
    static let weatherUsesFahrenheit = Key<Bool>(
        "weatherUsesFahrenheit",
        default: Locale.current.measurementSystem == .us
    )

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

    static let companionNotificationsEnabled = Key<Bool>("companionNotificationsEnabled", default: true)

    static let hasCompletedOnboarding = Key<Bool>("hasCompletedPebbleOnboarding", default: false)

    static let activeWatchfaceID = Key<UUID?>("activeWatchfaceID")

    static let favoriteWatchfaceIDs = Key<[UUID]>("favoriteWatchfaceIDs", default: [])

    static let healthKitLastExportDate = Key<Date>("healthKitLastExportDate", default: .distantPast)
}

extension DownloadedFirmware: Defaults.Serializable {}
extension WeatherPlace: Defaults.Serializable {}
extension PebbleActivitySettings: Defaults.Serializable {}
extension PebbleHeartRateSettings: Defaults.Serializable {}
