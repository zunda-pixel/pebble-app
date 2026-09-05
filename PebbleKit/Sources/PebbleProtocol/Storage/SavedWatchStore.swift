public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct SavedWatch: Codable, Equatable, Identifiable, Sendable {
    public var id: WatchID
    public var name: String
    public var model: WatchModel
    public var firmwareVersion: String?
    public var serialNumber: String?
    public var lastBatteryLevel: Int?
    public var lastConnectedAt: Date
    public var automaticallyConnects: Bool
    /// The board revision, remembered so firmware can be chosen for this watch
    /// while it is away.
    public var board: WatchBoard? = nil
}

public actor SavedWatchStore {
    private var fileURL: URL
    private var watches: [SavedWatch]?

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("watches.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func allWatches() throws -> [SavedWatch] {
        try loadIfNeeded()
        return watches ?? []
    }

    @discardableResult
    public func record(_ device: ConnectedWatch) throws -> [SavedWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        let previous = updated.first { $0.id == device.id }
        let watch = SavedWatch(
            id: device.id,
            name: device.name,
            model: device.model,
            firmwareVersion: device.firmwareVersion,
            serialNumber: device.serialNumber,
            lastBatteryLevel: device.batteryLevel,
            lastConnectedAt: Date(),
            automaticallyConnects: previous?.automaticallyConnects ?? true,
            board: device.board ?? previous?.board
        )
        updated.removeAll { $0.id == device.id }
        updated.insert(watch, at: 0)
        try persist(updated)
        return updated
    }

    @discardableResult
    public func setAutomaticallyConnects(_ enabled: Bool, watchID: WatchID) throws -> [SavedWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        guard let index = updated.firstIndex(where: { $0.id == watchID }) else { return updated }
        updated[index].automaticallyConnects = enabled
        try persist(updated)
        return updated
    }

    @discardableResult
    public func remove(watchID: WatchID) throws -> [SavedWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        updated.removeAll { $0.id == watchID }
        try persist(updated)
        return updated
    }

    /// A file that cannot be decoded is moved aside rather than thrown at every
    /// caller for ever. This store used to hand the `DecodingError` back, and
    /// because nothing ever cached the failure the next read did it again: the
    /// screen said "Saved watches could not be loaded." and no watch could be
    /// saved again, with no way out but deleting the file by hand.
    ///
    /// There is nothing to rebuild a watch list from, so what comes back is
    /// empty and the reader adds their watch again — which they can.
    private func loadIfNeeded() throws {
        guard watches == nil else { return }
        watches = try PersistentJSON.loadRecovering([SavedWatch].self, from: fileURL) ?? []
    }

    private func persist(_ updated: [SavedWatch]) throws {
        try PersistentJSON.save(updated, to: fileURL)
        watches = updated
    }
}
