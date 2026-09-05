public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The watch's own settings, as far as the firmware lets a phone write them.
@MainActor
@Observable
public final class WatchSettingsModel {
    /// Keyed by `WatchSetting.rawValue`, which is what the stored preference
    /// holds and what the firmware reads.
    public internal(set) var values: [String: Bool] = [:]
    public internal(set) var activity = ActivitySettings()
    public internal(set) var heartRate = HeartRateSettings()
    public internal(set) var feedback: FeatureFeedback?
}
