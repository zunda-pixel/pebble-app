public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The pins on the watch's timeline and the reminders beside them.
@MainActor
@Observable
public final class TimelineModel {
    public internal(set) var pins: [TimelinePin] = []
    public internal(set) var reminders: [TimelinePin] = []
    /// Whether the watch shows its Reminders app at all. The firmware hides it
    /// unless the phone claims the capability and says the app is enabled.
    public internal(set) var isReminderAppEnabled = true
    public internal(set) var feedback: FeatureFeedback?
    public internal(set) var reminderFeedback: FeatureFeedback?
}
