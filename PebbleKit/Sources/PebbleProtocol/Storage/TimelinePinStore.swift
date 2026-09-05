public import Foundation

public actor TimelinePinStore {
    private var fileURL: URL
    /// Which pin the app last gave which watch. BlobDB cannot be listed, so
    /// without this there is no way to name a pin the watch has and the app has
    /// forgotten — and a delete is only queued at the moment a pin is let go of,
    /// which is no help if that moment was missed or the queue was lost.
    private var writtenURL: URL
    /// Which item in the phone's own app stands for which one here.
    ///
    /// The two are one reminder kept in two places, and neither knows the
    /// other's name: without this an edit becomes a second reminder, and a
    /// reminder let go of on one side cannot be found on the other.
    private var mirroredURL: URL

    public init(fileURL: URL? = nil, writtenURL: URL? = nil) {
        let items = fileURL ?? applicationSupportURL("timeline.json")
        self.fileURL = items
        // Named after the items it accounts for: pins and reminders are two of
        // these stores, and one shared file would have each claiming to have
        // written the other's.
        self.writtenURL = writtenURL ?? items
            .deletingLastPathComponent()
            .appending(path: "\(items.deletingPathExtension().lastPathComponent)-written.json")
        self.mirroredURL = items
            .deletingLastPathComponent()
            .appending(path: "\(items.deletingPathExtension().lastPathComponent)-mirrored.json")
    }

    public func mirroredIdentifiers() throws -> [UUID: String] {
        try PersistentJSON.loadRecovering([UUID: String].self, from: mirroredURL) ?? [:]
    }

    public func setMirroredIdentifiers(_ identifiers: [UUID: String]) throws {
        try PersistentJSON.save(identifiers, to: mirroredURL)
    }

    public func writtenPinIDs(deviceID: String) throws -> Set<UUID> {
        Set(try writtenStates()[deviceID] ?? [])
    }

    public func setWrittenPinIDs(_ pinIDs: Set<UUID>, deviceID: String) throws {
        var states = try writtenStates()
        states[deviceID] = Array(pinIDs)
        try PersistentJSON.save(states, to: writtenURL)
    }

    public func forgetWrittenPinIDs(deviceID: String) throws {
        var states = try writtenStates()
        states[deviceID] = nil
        try PersistentJSON.save(states, to: writtenURL)
    }

    private func writtenStates() throws -> [String: [UUID]] {
        try PersistentJSON.loadRecovering([String: [UUID]].self, from: writtenURL) ?? [:]
    }

    public func pins() throws -> [PebbleTimelinePin] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([PebbleTimelinePin].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ pins: [PebbleTimelinePin]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pins).write(to: fileURL, options: .atomic)
    }
}
