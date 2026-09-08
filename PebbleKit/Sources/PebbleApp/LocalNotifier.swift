import Foundation
import UserNotifications

/// Local notifications on the phone, behind a face a test can stand in for.
///
/// The system centre needs a real app bundle — `UNUserNotificationCenter`
/// aborts in a bare test process — so the model talks to this and the tests
/// hand it a recorder.
@MainActor
public protocol LocalNotifying {
    /// Whether the person allowed notifications, asking them if they have not
    /// been asked. Called only when the reader turns a notifying feature on:
    /// nothing here asks ahead of a reason to.
    func requestAuthorization() async -> Bool
    /// Posts one, replacing any earlier one under the same identifier.
    func post(identifier: String, title: String, body: String) async
    /// Takes one back, delivered or not — for a notification whose moment has
    /// passed, like an update the reader has already started installing.
    func remove(identifier: String) async
}

/// The real centre. Touches `UNUserNotificationCenter` only inside its
/// methods, so merely constructing the model in a test process is safe.
public struct SystemLocalNotifier: LocalNotifying {
    /// Whether this process can talk to the notification centre at all.
    ///
    /// `UNUserNotificationCenter.current()` does not fail in a process without
    /// an app bundle — it aborts it. Any test that reaches this by a road
    /// nobody thought to stub takes the whole test process and every suite
    /// running beside it, which is precisely what happened the first time
    /// `performFirmwareUpdate` learned to take a notification down. An app
    /// bundle ends in `.app`; the xctest runner does not.
    private static let hasNotificationCenter = Bundle.main.bundleURL.pathExtension == "app"

    public init() {}

    public func requestAuthorization() async -> Bool {
        guard Self.hasNotificationCenter else { return false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    public func post(identifier: String, title: String, body: String) async {
        guard Self.hasNotificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Nil trigger: now. The point of these is the moment they mark.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    public func remove(identifier: String) async {
        guard Self.hasNotificationCenter else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
