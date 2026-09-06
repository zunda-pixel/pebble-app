public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// What reaches the watch as a notification, and what became of what did.
@MainActor
@Observable
public final class NotificationsModel {
    public internal(set) var companionEnabled = true
    public internal(set) var preferences = NotificationDeliveryPreferences()
    /// Newest first. Only the notifications this app sent: another phone app's
    /// go to the watch over ANCS, where no app can see them.
    public internal(set) var sent: [SentNotification] = []
    public internal(set) var sourceApps: [NotificationSourceApp] = []
    /// The answer to sending a test notification, which is asked for on a
    /// watch's own detail screen and belongs there.
    public internal(set) var feedback: FeatureFeedback?

    /// The answer to changing a delivery setting, which is asked for on the
    /// notification settings screen.
    ///
    /// Apart from `feedback` because one field shared by both put the reply to
    /// a switch flicked in Settings onto a watch's detail page — the same
    /// fault as #60, which is what that field was split up to cure.
    public internal(set) var settingsFeedback: FeatureFeedback?
}
