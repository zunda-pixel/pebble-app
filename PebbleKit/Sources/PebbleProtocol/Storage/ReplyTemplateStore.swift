public import Foundation

/// The replies the reader keeps for the watch, where the notification
/// extension — a process of its own, which reads them for each notification
/// it forwards — can read them too.
public actor ReplyTemplateStore {
    public struct ContainerUnavailable: Error, Equatable, Sendable {}

    private let fileURL: URL?

    /// Nil when this process has no directory the extension shares.
    public init(directory: StorageDirectory?) {
        fileURL = directory?.file("reply-templates.json")
    }

    /// Nil when none have ever been saved, which is not the same as the reader
    /// having deleted every one. Empty where there is nowhere to keep them.
    public func templates() throws -> [ReplyTemplate]? {
        guard let fileURL else { return [] }
        return try PersistentJSON.loadRecovering([ReplyTemplate].self, from: fileURL)
    }

    public func save(_ templates: [ReplyTemplate]) throws {
        guard let fileURL else { throw ContainerUnavailable() }
        try PersistentJSON.save(templates, to: fileURL)
    }
}
