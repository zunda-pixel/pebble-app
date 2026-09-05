import Foundation
import MemberwiseInit

/// One piece of queued work and the watches that already have it.
///
/// The queue used to be a list of the work alone, and a flush sent each item to
/// every connected watch and kept it if *any* of them refused. With two watches
/// that means the one which took it gets it again on the next flush: shown twice,
/// buzzed twice. Which watch has what belongs to the item.
@MemberwiseInit(.public)
public struct PendingDelivery<Work: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var work: Work
    public var deliveredTo: Set<WatchID> = []

    public func isOwed(by watchID: WatchID) -> Bool {
        !deliveredTo.contains(watchID)
    }
}

/// Reads a queue, accepting one written before the watches were tracked per
/// item — nobody has had those yet, which is what an empty set says. Tried in
/// this order because `loadRecovering` moves a file it cannot decode out of the
/// way, which would take the older shape with it.
func loadQueue<Work: Codable & Equatable & Sendable>(
    _ work: Work.Type,
    from url: URL
) throws -> [PendingDelivery<Work>] {
    if let stored = try? PersistentJSON.load([PendingDelivery<Work>].self, from: url) {
        return stored
    }
    if let queued = try? PersistentJSON.load([Work].self, from: url) {
        return queued.map { PendingDelivery(work: $0) }
    }
    return try PersistentJSON.loadRecovering([PendingDelivery<Work>].self, from: url) ?? []
}
