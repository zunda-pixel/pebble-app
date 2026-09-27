public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// What one watch handed over when asked: a screenshot, its logs, a crash
/// report, and the answer to each request.
public struct WatchDiagnosticsState: Equatable {
    public var latestScreenshot: WatchScreenshot?
    public var screenshotURL: URL?
    public var watchLogLines: [WatchLogLine] = []
    public var watchLogsURL: URL?
    public var coredumpURL: URL?
    public var isTakingScreenshot = false
    public var isGatheringWatchLogs = false
    public var isCollectingCoredump = false
    /// One per thing that can be asked for: a screenshot that failed says
    /// nothing about the logs, and the screen shows each beside its own button.
    public var feedback: [WatchDiagnostic: FeatureFeedback] = [:]

    public init() {}
}

/// What the watches can be asked to hand over when something has gone wrong,
/// and the report the phone writes about itself.
///
/// By watch, because each watch has its own diagnostics screen: one watch's
/// screenshot drawn on another's page is a picture of the wrong watch.
@MainActor
@Observable
public final class DiagnosticsModel {
    public internal(set) var watches: [WatchID: WatchDiagnosticsState] = [:]
    /// App logs come from whichever watch is running the app, and the switch
    /// is sent to every watch, so these are one list.
    public internal(set) var applicationLogLines: [WatchLogLine] = []
    public internal(set) var isApplicationLoggingEnabled = false
    public internal(set) var reportURL: URL?
    /// The diagnostic report's answer, on the settings screen that asks for it.
    public internal(set) var reportFeedback: FeatureFeedback?

    public internal(set) subscript(watchID: WatchID) -> WatchDiagnosticsState {
        get { watches[watchID] ?? WatchDiagnosticsState() }
        set { watches[watchID] = newValue }
    }
}
