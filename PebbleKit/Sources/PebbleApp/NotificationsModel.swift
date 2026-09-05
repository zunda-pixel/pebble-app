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
    public internal(set) var feedback: FeatureFeedback?
}
