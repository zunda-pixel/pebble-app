public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The watch's own settings, as far as the firmware lets a phone write them.
@MainActor
@Observable
public final class WatchSettingsModel {
    /// Keyed by `WatchSetting.rawValue`, which is what the stored preference
    /// holds and what the firmware reads. The value is the number the firmware
    /// keeps: 0 or 1 for a switch, and one of a small set for the rest.
    public internal(set) var values: [String: Int] = [:]
    /// What each button's long press launches, keyed the same way `values` is.
    /// Absent means the firmware's own default — Quiet Time on Back, nothing
    /// on the rest — which is different from a stored "off".
    public internal(set) var quickLaunch: [String: QuickLaunchAssignment] = [:]
    public internal(set) var activity = ActivitySettings()
    public internal(set) var heartRate = HeartRateSettings()
    public internal(set) var feedback: FeatureFeedback?
}
