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
    /// The revision burned in at the factory, remembered so a watch's page can
    /// show it while the watch is away, as it already does its serial.
    ///
    /// Optional, like `board` above and for the same reason: a synthesized
    /// `init(from:)` does not fall back on a property's default value, so a
    /// non-optional field added here would refuse every `watches.json` written
    /// before it existed.
    public var hardwareRevision: String? = nil
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
    public func record(_ watch: ConnectedWatch) throws -> [SavedWatch] {
        try loadIfNeeded()
        var updated = watches ?? []
        let previous = updated.first { $0.id == watch.id }
        let watch = SavedWatch(
            id: watch.id,
            name: watch.name,
            model: watch.model,
            firmwareVersion: watch.firmwareVersion,
            serialNumber: watch.serialNumber,
            lastBatteryLevel: watch.batteryLevel,
            lastConnectedAt: Date(),
            automaticallyConnects: previous?.automaticallyConnects ?? true,
            board: watch.board ?? previous?.board,
            // Kept from the last connection that knew it, the way the board is:
            // a connection that does not say should not erase what is known.
            hardwareRevision: watch.hardwareRevision ?? previous?.hardwareRevision
        )
        updated.removeAll { $0.id == watch.id }
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
