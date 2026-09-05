public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// What the watch can be asked to hand over when something has gone wrong: a
/// screenshot, its logs, a crash report.
@MainActor
@Observable
public final class DiagnosticsModel {
    public internal(set) var latestScreenshot: WatchScreenshot?
    public internal(set) var screenshotURL: URL?
    public internal(set) var watchLogLines: [WatchLogLine] = []
    public internal(set) var watchLogsURL: URL?
    public internal(set) var applicationLogLines: [WatchLogLine] = []
    public internal(set) var isApplicationLoggingEnabled = false
    public internal(set) var coredumpURL: URL?
    public internal(set) var reportURL: URL?
    public internal(set) var isTakingScreenshot = false
    public internal(set) var isGatheringWatchLogs = false
    public internal(set) var isCollectingCoredump = false
    /// One per thing that can be asked for: a screenshot that failed says
    /// nothing about the logs, and the screen shows each beside its own button.
    public internal(set) var feedback: [WatchDiagnostic: FeatureFeedback] = [:]
}
