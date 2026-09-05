public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct StoredAppMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var applicationID: UUID
    public var tuples: [AppMessageTuple]
    public var createdAt: Date = Date()
}

public actor PendingAppMessageStore {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-appmessages.json")
    }

    /// A plain list: an app message is addressed to an application and sent to
    /// one watch, so there is no per-watch delivery to remember.
    public func messages() throws -> [StoredAppMessage] {
        try PersistentJSON.loadRecovering([StoredAppMessage].self, from: fileURL) ?? []
    }

    public func save(_ messages: [StoredAppMessage]) throws {
        try PersistentJSON.save(messages, to: fileURL)
    }
}
