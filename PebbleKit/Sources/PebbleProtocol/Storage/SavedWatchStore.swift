public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct SavedPebbleWatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: PebbleWatchModel
    public var firmwareVersion: String?
    public var serialNumber: String?
    public var lastBatteryLevel: Int?
    public var lastConnectedAt: Date
    public var automaticallyConnects: Bool
    /// The board revision, remembered so firmware can be chosen for this watch
    /// while it is away.
    public var board: PebbleWatchBoard? = nil
}

public actor SavedWatchStore {
    private var fileURL: URL
    private var watches: [SavedPebbleWatch]?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public func allWatches() throws -> [SavedPebbleWatch] {
        try loadIfNeeded()
        return watches ?? []
    }

    @discardableResult
    public func record(_ device: PebbleDevice) throws -> [SavedPebbleWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        let previous = updated.first { $0.id == device.id }
        let watch = SavedPebbleWatch(
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
    public func setAutomaticallyConnects(_ enabled: Bool, watchID: String) throws -> [SavedPebbleWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        guard let index = updated.firstIndex(where: { $0.id == watchID }) else { return updated }
        updated[index].automaticallyConnects = enabled
        try persist(updated)
        return updated
    }

    @discardableResult
    public func remove(watchID: String) throws -> [SavedPebbleWatch] {
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
        watches = try PersistentJSON.loadRecovering([SavedPebbleWatch].self, from: fileURL) ?? []
    }

    private func persist(_ updated: [SavedPebbleWatch]) throws {
        try PersistentJSON.save(updated, to: fileURL)
        watches = updated
    }

    private static func defaultFileURL() -> URL {
        applicationSupportURL("watches.json")
    }
}
