public import Foundation
import DequeModule

/// Order is the whole point: the protocol numbers its packets, and one
/// overtaking another stalls the session until it times out.
struct PendingNotificationQueue: Equatable, Sendable {
    private var packets: Deque<(centralID: String, value: Data)> = []

    var isEmpty: Bool {
        packets.isEmpty
    }

    var count: Int {
        packets.count
    }

    var first: (centralID: String, value: Data)? {
        packets.first
    }

    func holdsPackets(for centralID: String) -> Bool {
        packets.contains { $0.centralID == centralID }
    }

    mutating func append(_ value: Data, for centralID: String) {
        packets.append((centralID, value))
    }

    mutating func removeFirst() {
        packets.removeFirst()
    }

    mutating func removeAll(for centralID: String) {
        packets.removeAll { $0.centralID == centralID }
    }

    mutating func removeAll() {
        packets.removeAll()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.packets.count == rhs.packets.count
            && zip(lhs.packets, rhs.packets).allSatisfy { $0.centralID == $1.centralID && $0.value == $1.value }
    }
}
