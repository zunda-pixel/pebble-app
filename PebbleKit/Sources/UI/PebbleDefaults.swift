import Defaults
import Foundation

/// Every preference the app stores, in one place and with its type.
///
/// These were string literals repeated across the files that read and wrote
/// them, which is how `autoResumeFirmwareUpdate` came to be read two different
/// ways and how the watchface identifiers ended up converted to and from
/// strings by hand at each site.
extension Defaults.Keys {
    /// Where the application catalog is fetched from.
    static let catalogSource = Key<String?>("appCatalogSource")

    /// Whether a firmware transfer interrupted by a disconnect resumes on the
    /// next connection.
    static let autoResumeFirmwareUpdate = Key<Bool>("autoResumeFirmwareUpdate", default: true)

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
