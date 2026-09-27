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

    /// `name` because the app keeps two of these — the timeline's pins and the
    /// reminders — and one shared file would have each claiming to have written
    /// the other's.
    public init(directory: StorageDirectory = .applicationSupport, name: String = "timeline") {
        self.init(fileURL: directory.file("\(name).json"))
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let stem = fileURL.deletingPathExtension().lastPathComponent
        writtenURL = fileURL
            .deletingLastPathComponent()
            .appending(path: "\(stem)-written.json")
        mirroredURL = fileURL
            .deletingLastPathComponent()
            .appending(path: "\(stem)-mirrored.json")
    }

    public func mirroredIdentifiers() throws -> [UUID: String] {
        let pairs = try PersistentJSON.loadRecovering([MirroredReminder].self, from: mirroredURL) ?? []
        return Dictionary(pairs.map { ($0.id, $0.externalIdentifier) }, uniquingKeysWith: { _, latest in latest })
    }

    public func setMirroredIdentifiers(_ identifiers: [UUID: String]) throws {
        try PersistentJSON.save(
            identifiers
                .map { MirroredReminder(id: $0.key, externalIdentifier: $0.value) }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            to: mirroredURL
        )
    }

    public func writtenPinIDs(watchID: WatchID) throws -> Set<UUID> {
        Set(try writtenStates()[watchID]?.map(\.id) ?? [])
    }

    /// Names the pins without saying what they were written as.
    ///
    /// For a removal, and for the items a watch made, which it holds already
    /// and so were never written as anything. A pin that arrives with no
    /// digest keeps the one it already had, so noting one more held item does
    /// not re-send all the others.
    public func setWrittenPinIDs(_ pinIDs: Set<UUID>, watchID: WatchID) throws {
        var states = try writtenStates()
        let existing = Dictionary(
            (states[watchID] ?? []).map { ($0.id, $0.digest) },
            uniquingKeysWith: { _, latest in latest }
        )
        states[watchID] = pinIDs
            .map { WrittenPin(id: $0, digest: existing[$0] ?? "") }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        try PersistentJSON.save(states, to: writtenURL)
    }

    /// Which pins this watch was given, and the digest of the bytes each was
    /// written as. A pin whose digest still matches is one the watch already
    /// holds, so writing it again would cost a round trip to leave the watch
    /// exactly as it is.
    public func writtenPinDigests(watchID: WatchID) throws -> [UUID: String] {
        Dictionary(
            (try writtenStates()[watchID] ?? []).map { ($0.id, $0.digest) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func setWrittenPinDigests(_ digests: [UUID: String], watchID: WatchID) throws {
        var states = try writtenStates()
        // Sorted for the same reason `PersistentJSON` sorts keys: this file is
        // read by a person diagnosing a fault.
        states[watchID] = digests
            .map { WrittenPin(id: $0.key, digest: $0.value) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        try PersistentJSON.save(states, to: writtenURL)
    }

    public func forgetWrittenPinIDs(watchID: WatchID) throws {
        var states = try writtenStates()
        states[watchID] = nil
        try PersistentJSON.save(states, to: writtenURL)
    }

    /// The digest was added after the plain identifiers, and a file from before
    /// then still names every pin its watch was given — which is the only way
    /// to find one the app has since forgotten. Such a file is read for its
    /// identifiers and each given a digest no pin can match, so every pin is
    /// written once more and left alone after that.
    private func writtenStates() throws -> [WatchID: [WrittenPin]] {
        do {
            return try PersistentJSON.load([WatchID: [WrittenPin]].self, from: writtenURL) ?? [:]
        } catch where PersistentJSON.isCorrupt(error) {}
        do {
            let identifiers = try PersistentJSON.load([WatchID: [UUID]].self, from: writtenURL) ?? [:]
            return identifiers.mapValues { $0.map { WrittenPin(id: $0, digest: "") } }
        } catch where PersistentJSON.isCorrupt(error) {}
        // Neither shape, the same recovery as the files beside it: a written
        // record that cannot be read is worse than none, because every read
        // would fail from here on.
        try PersistentJSON.quarantine(writtenURL)
        return [:]
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

/// A pin the app has written to a watch, and a digest of the bytes it wrote.
///
/// An array of these rather than a `[UUID: String]`: `UUID` is not a
/// `CodingKeyRepresentable`, so that dictionary encodes as an alternating array
/// of strings — which is indistinguishable from the array of identifiers this
/// file used to hold, and would have read back as pins paired off as each
/// other's digests. An array of objects cannot be read as an array of strings.
private struct WrittenPin: Codable, Sendable {
    var id: UUID
    var digest: String
}

/// One reminder as this app and the phone's Reminders app each name it.
///
/// An array of these for the reason `WrittenPin` is one: a `[UUID: String]`
/// encodes as a flat array of alternating strings, which says nothing about
/// which of them is a key.
private struct MirroredReminder: Codable, Sendable {
    var id: UUID
    var externalIdentifier: String
}
