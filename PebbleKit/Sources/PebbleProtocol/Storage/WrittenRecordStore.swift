public import Foundation

/// A kind of BlobDB record the app writes for something the reader can later
/// take away.
public enum WrittenRecordKind: String, Codable, CodingKeyRepresentable, Sendable {
    case appGlance
    case notificationSourceApp
    case weather
}

/// Which records each watch was given, kept across connections.
///
/// BlobDB has no listing, so the only way to take back a record from a watch
/// that was away when the reader deleted it is to remember having written it.
/// What a connection holds in memory is cleared with the link.
public actor WrittenRecordStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("written-records.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func keys(_ kind: WrittenRecordKind, watchID: WatchID) throws -> Set<String> {
        try records()[watchID]?[kind] ?? []
    }

    public func insert(_ key: String, _ kind: WrittenRecordKind, watchID: WatchID) throws {
        var records = try records()
        guard records[watchID, default: [:]][kind, default: []].insert(key).inserted else { return }
        try PersistentJSON.save(records, to: fileURL)
    }

    public func remove(_ key: String, _ kind: WrittenRecordKind, watchID: WatchID) throws {
        var records = try records()
        guard records[watchID]?[kind]?.remove(key) != nil else { return }
        try PersistentJSON.save(records, to: fileURL)
    }

    public func forget(watchID: WatchID) throws {
        var records = try records()
        guard records.removeValue(forKey: watchID) != nil else { return }
        try PersistentJSON.save(records, to: fileURL)
    }

    private func records() throws -> [WatchID: [WrittenRecordKind: Set<String>]] {
        try PersistentJSON.loadRecovering([WatchID: [WrittenRecordKind: Set<String>]].self, from: fileURL) ?? [:]
    }
}
