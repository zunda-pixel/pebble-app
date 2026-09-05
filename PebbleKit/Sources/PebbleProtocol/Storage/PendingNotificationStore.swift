public import Foundation

/// Work queued while no watch is connected, kept so a reconnect can finish it.
public actor PendingNotificationStore {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-notifications.json")
    }

    public func notifications() throws -> [PendingDelivery<PebbleTimelineNotification>] {
        try loadQueue(PebbleTimelineNotification.self, from: fileURL)
    }

    public func save(_ notifications: [PendingDelivery<PebbleTimelineNotification>]) throws {
        try PersistentJSON.save(notifications, to: fileURL)
    }
}
