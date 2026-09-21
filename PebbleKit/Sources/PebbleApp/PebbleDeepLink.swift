public import Foundation

/// A link the app was opened with, sorted into what it asks for — or into why
/// it is refused. The taxonomy is the official app's
/// (`PebbleDeepLinkHandler.kt`) wherever the two share a feature, so a link
/// written for one opens in the other.
public enum PebbleDeepLink: Equatable, Sendable {
    /// `pebble://navbar/{section}` or `pebble://show-watches[/{serial}]`.
    /// The serial is accepted and dropped: showing the list is the useful part.
    case section(AppSection)
    /// `pebble://appstore/{id}` — the store's own identifier, not a UUID.
    /// The official app's `source` query names one of several feeds; until
    /// this app has several (#97) the selected source answers, and the
    /// parameter is accepted and ignored rather than refused.
    case storeApplication(id: String)
    /// A `.pbw`, `.pbz` or `.pbl` offered by URL — https, or a file handed
    /// over by the system. Fetched and shown before anything is sent.
    case package(PackageKind, URL)

    public enum PackageKind: String, Equatable, Sendable {
        case watchApp = "pbw"
        case firmware = "pbz"
        case languagePack = "pbl"
    }

    public enum Refusal: Error, Equatable, Sendable {
        /// Nothing this app answers to. Refused by name so that a typo does
        /// not quietly do the nearest other thing.
        case unknown
        /// A package offered over plain http would arrive rewritable, and a
        /// package is code the watch will run.
        case insecurePackageSource
        /// `pebble://add-store-feed` — multiple store feeds are #97.
        case storeFeedsNotSupported
        /// `pebble://custom-boot-config-url` — accounts are #20.
        case accountsNotSupported
        /// `pebblejs://close` belongs to the settings page's own web view,
        /// which answers it in place; arriving from outside there is no
        /// session to match it to.
        case configurationSessionOnly
    }

    public static func parse(_ url: URL) -> Result<PebbleDeepLink, Refusal> {
        switch url.scheme?.lowercased() {
        case "pebble":
            return parsePebbleScheme(url)
        case "pebblejs":
            return .failure(.configurationSessionOnly)
        case "https", "http", "file":
            guard let kind = PackageKind(rawValue: url.pathExtension.lowercased()) else {
                return .failure(.unknown)
            }
            guard url.scheme?.lowercased() != "http" else {
                return .failure(.insecurePackageSource)
            }
            return .success(.package(kind, url))
        default:
            return .failure(.unknown)
        }
    }

    private static func parsePebbleScheme(_ url: URL) -> Result<PebbleDeepLink, Refusal> {
        let segments = url.path(percentEncoded: false)
            .split(separator: "/").map(String.init)
        switch url.host()?.lowercased() {
        case "appstore":
            guard segments.count == 1, let id = segments.first, !id.isEmpty else {
                return .failure(.unknown)
            }
            return .success(.storeApplication(id: id))
        case "navbar":
            guard segments.count == 1,
                  let section = AppSection(rawValue: segments[0].lowercased()) else {
                return .failure(.unknown)
            }
            return .success(.section(section))
        case "show-watches":
            guard segments.count <= 1 else { return .failure(.unknown) }
            return .success(.section(.watches))
        case "add-store-feed":
            return .failure(.storeFeedsNotSupported)
        case "custom-boot-config-url":
            return .failure(.accountsNotSupported)
        default:
            return .failure(.unknown)
        }
    }
}
