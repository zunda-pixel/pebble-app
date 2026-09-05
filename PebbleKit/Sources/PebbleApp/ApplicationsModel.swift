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
    public internal(set) var activeWatchfaceID: UUID?
    public internal(set) var isLoading = false
    public internal(set) var isImporting = false
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
}
