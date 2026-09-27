public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The reader's own collection of watch apps and watchfaces.
@MainActor
@Observable
public final class ApplicationsModel {
    public internal(set) var apps: [WatchApplication] = []
    public internal(set) var watchfaces: [WatchApplication] = []
    /// The watchface each watch is showing, as it last said.
    public internal(set) var activeWatchfaceIDs: [WatchID: UUID] = [:]
    public internal(set) var isLoading = false
    public internal(set) var isImporting = false
    /// The answer to importing a package from a file, which is asked for on the
    /// catalogue screen and by dropping one on the applications screen.
    ///
    /// Apart from `libraryFeedback` because the catalogue is pushed over the
    /// applications screen: sharing the field would have put the reply to
    /// removing an app or activating a watchface onto the store's screen. It is
    /// drawn on both screens because either of them can start an import.
    public internal(set) var importFeedback: FeatureFeedback?
    public internal(set) var libraryFeedback: FeatureFeedback?
    /// The library operations — importing, removing, reordering, synchronizing —
    /// are phone-side and take turns: each rewrites the one library and then
    /// pushes it to every watch, so this stays a single value rather than moving
    /// onto a connection. What belongs to a watch is the transfer, and that lives
    /// on `WatchConnection`.
    public internal(set) var managementOperation: ApplicationManagementOperation?
    public internal(set) var managementFeedback: FeatureFeedback?
    public internal(set) var configurationApplication: WatchApplication?
    public internal(set) var configurationURL: URL?
    public internal(set) var installedIDsByWatch: [WatchID: Set<UUID>] = [:]

    public var all: [WatchApplication] { apps + watchfaces }

    /// The watchface this watch is showing — or, asked about no watch in
    /// particular, whether any is showing it is the question, and this answers
    /// with one of them.
    public func activeWatchfaceID(on watchID: WatchID?) -> UUID? {
        guard let watchID else { return activeWatchfaceIDs.values.first }
        return activeWatchfaceIDs[watchID]
    }

    public func isActiveWatchface(_ applicationID: UUID, on watchID: WatchID?) -> Bool {
        guard let watchID else { return activeWatchfaceIDs.values.contains(applicationID) }
        return activeWatchfaceIDs[watchID] == applicationID
    }

    /// The settings page that is showing, if one is.
    ///
    /// Named by its address so the sheet showing it belongs to one page rather
    /// than to the fact that a page is showing. Presented on a `Bool` and
    /// branched on inside, the web view was built twice for one opening — twice
    /// on the reader's phone, 69 ms apart, and the second load was still going
    /// 3.35 seconds later while the first had been thrown away.
    public var configurationPage: ConfigurationPage? {
        configurationURL.map(ConfigurationPage.init)
    }
}

/// A settings page, identified by where it came from.
public struct ConfigurationPage: Identifiable, Sendable, Equatable {
    public var url: URL
    public var id: URL { url }

    public init(url: URL) {
        self.url = url
    }
}
