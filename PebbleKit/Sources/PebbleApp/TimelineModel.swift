public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The pins on the watch's timeline and the reminders beside them.
@MainActor
@Observable
public final class TimelineModel {
    public internal(set) var pins: [TimelinePin] = []
    /// The phone's calendars, for the per-calendar switches. Filled when the
    /// calendar settings are opened; empty until then, so nothing prompts for
    /// calendar access on behalf of a screen nobody visited.
    var calendars: [PhoneCalendar] = []
    public internal(set) var reminders: [TimelinePin] = []
    /// Whether the watch shows its Reminders app at all. The firmware hides it
    /// unless the phone claims the capability and says the app is enabled.
    public internal(set) var isReminderAppEnabled = true
    /// When a reminder from the Reminders app with a date and no time buzzes,
    /// in minutes after midnight.
    public internal(set) var allDayReminderMinutes = 9 * 60
    public internal(set) var feedback: FeatureFeedback?
    public internal(set) var reminderFeedback: FeatureFeedback?
    /// The synchronization pass in flight, if one is. Two at once read the
    /// same queue and send it twice, so a second caller waits for the first.
    @ObservationIgnored var synchronizationTask: Task<Set<WatchID>, Never>?
}
