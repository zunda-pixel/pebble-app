public import Foundation
import MemberwiseInit

/// A notification this app sent to a watch, and what became of it.
///
/// Only this app's own. A notification from another phone app goes to the watch
/// over ANCS, which is a conversation between iOS and the watch that no app can
/// listen in on — the screen says so rather than showing a list that looks
/// short for no reason.
@MemberwiseInit(.public)
public struct SentNotification: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var appName: String
    public var title: String
    public var body: String
    public var sentAt: Date = Date()
    /// Empty when no watch would take it; it is then queued and appears again
    /// as its own entry when a watch does.
    public var watchNames: [String] = []
}

public extension SentNotification {
    // Not the synthesized decoder: that reads a field with a default through
    // `decode`, so a file written before the field existed fails to decode and
    // `PersistentJSON.loadRecovering` sets the whole file aside.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appName = try container.decode(String.self, forKey: .appName)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        watchNames = try container.decodeIfPresent([String].self, forKey: .watchNames) ?? []
    }
}

public actor SentNotificationStore {
    /// Long enough to answer "did it go?" about this morning, short enough that
    /// the file stays small and nothing is kept that nobody will read.
    static let capacity = 100

    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("sent-notifications.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func notifications() throws -> [SentNotification] {
        try PersistentJSON.loadRecovering([SentNotification].self, from: fileURL) ?? []
    }

    public func record(_ notification: SentNotification) throws -> [SentNotification] {
        var kept = try notifications()
        kept.insert(notification, at: 0)
        if kept.count > Self.capacity {
            kept.removeLast(kept.count - Self.capacity)
        }
        try PersistentJSON.save(kept, to: fileURL)
        return kept
    }

    public func clear() throws {
        try PersistentJSON.save([SentNotification](), to: fileURL)
    }
}
