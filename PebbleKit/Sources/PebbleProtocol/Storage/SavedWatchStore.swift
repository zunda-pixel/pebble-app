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

    private func loadIfNeeded() throws {
        guard watches == nil else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            watches = []
            return
        }
        watches = try JSONDecoder().decode([SavedPebbleWatch].self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ updated: [SavedPebbleWatch]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(updated).write(to: fileURL, options: .atomic)
        watches = updated
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Pebble", directoryHint: .isDirectory)
            .appending(path: "watches.json")
    }
}
