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

    public func writtenPinIDs(watchID: WatchID) throws -> Set<UUID> {
        Set(try writtenStates()[watchID] ?? [])
    }

    public func setWrittenPinIDs(_ pinIDs: Set<UUID>, watchID: WatchID) throws {
        var states = try writtenStates()
        states[watchID] = Array(pinIDs)
        try PersistentJSON.save(states, to: writtenURL)
    }

    public func forgetWrittenPinIDs(watchID: WatchID) throws {
        var states = try writtenStates()
        states[watchID] = nil
        try PersistentJSON.save(states, to: writtenURL)
    }

    private func writtenStates() throws -> [WatchID: [UUID]] {
        try PersistentJSON.loadRecovering([WatchID: [UUID]].self, from: writtenURL) ?? [:]
    }

    /// A file that cannot be decoded is moved aside, the same as the two
    /// dictionaries beside it. There is nothing to rebuild pins from here — the
    /// calendar and the phone's reminders put them back on the next
    /// synchronization — but handing the `DecodingError` back on every read
    /// would have meant no pin could be shown or saved again.
    public func pins() throws -> [TimelinePin] {
        try PersistentJSON.loadRecovering([TimelinePin].self, from: fileURL) ?? []
    }

    public func save(_ pins: [TimelinePin]) throws {
        try PersistentJSON.save(pins, to: fileURL)
    }
}
