public import Foundation

public enum PendingTimelineOperation: Codable, Equatable, Sendable {
    case upsert(TimelinePin)
    case delete(UUID)
}

public actor PendingTimelineOperationStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("pending-timeline.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func operations() throws -> [PendingTimelineOperation] {
        try PersistentJSON.loadRecovering([PendingTimelineOperation].self, from: fileURL) ?? []
    }

    public func save(_ operations: [PendingTimelineOperation]) throws {
        try PersistentJSON.save(operations, to: fileURL)
    }
}
