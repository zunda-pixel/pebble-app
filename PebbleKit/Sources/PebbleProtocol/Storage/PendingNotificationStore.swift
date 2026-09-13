public import Foundation

/// Work queued while no watch is connected, kept so a reconnect can finish it.
public actor PendingNotificationStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("pending-notifications.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func notifications() throws -> [PendingDelivery<TimelineNotification>] {
        try loadQueue(TimelineNotification.self, from: fileURL)
    }

    public func save(_ notifications: [PendingDelivery<TimelineNotification>]) throws {
        try PersistentJSON.save(notifications, to: fileURL)
    }
}
