public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct StoredAppMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var applicationID: UUID
    public var tuples: [AppMessageTuple]
    /// The watch whose app the script was answering. Nil for a script nobody
    /// on a watch started, which any watch may be given.
    public var watchID: WatchID? = nil
    public var createdAt: Date = Date()
}

public extension StoredAppMessage {
    // Not the synthesized decoder: that reads a field with a default through
    // `decode`, so a file written before the field existed fails to decode and
    // `PersistentJSON.loadRecovering` sets the whole file aside.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        applicationID = try container.decode(UUID.self, forKey: .applicationID)
        tuples = try container.decode([AppMessageTuple].self, forKey: .tuples)
        watchID = try container.decodeIfPresent(WatchID.self, forKey: .watchID)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

public actor PendingAppMessageStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("pending-appmessages.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A plain list: an app message is addressed to an application on one
    /// watch, so there is no per-watch delivery to remember.
    public func messages() throws -> [StoredAppMessage] {
        try PersistentJSON.loadRecovering([StoredAppMessage].self, from: fileURL) ?? []
    }

    public func save(_ messages: [StoredAppMessage]) throws {
        try PersistentJSON.save(messages, to: fileURL)
    }
}
