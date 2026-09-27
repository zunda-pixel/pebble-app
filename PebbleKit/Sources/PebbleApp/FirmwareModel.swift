public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// Where one watch's firmware update stands.
public struct WatchFirmwareState: Equatable {
    public var journal: FirmwareUpdateJournal?
    public var requiresConfirmation = false
    /// The newest release for this watch's board, once asked for.
    public var availableRelease: PebbleOSFirmwareRelease?
    public var feedback: FeatureFeedback?

    public init() {}
}

/// Firmware updates: what is published, what has been downloaded, and where a
/// started install got to — each by the watch it is for.
///
/// Per watch because the screens are. With one of each, a release checked for
/// one watch's board was offered on another watch's screen, where its package
/// would be refused, and the answer to one watch's install sat on every one.
@MainActor
@Observable
public final class FirmwareModel {
    public internal(set) var watches: [WatchID: WatchFirmwareState] = [:]
    /// What the firmware folder holds, by board. A watch's screen shows the one
    /// for its own board.
    public internal(set) var downloads: [DownloadedFirmware] = []

    public internal(set) subscript(watchID: WatchID) -> WatchFirmwareState {
        get { watches[watchID] ?? WatchFirmwareState() }
        set { watches[watchID] = newValue }
    }

    /// The newest package downloaded for this board.
    public func download(for board: WatchBoard?) -> DownloadedFirmware? {
        downloads
            .filter { $0.board == board }
            .max { PebbleOSFirmwareCatalog.isVersion($1.versionTag, newerThan: $0.versionTag) }
    }
}
