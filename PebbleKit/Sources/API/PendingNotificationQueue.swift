public import Foundation
import DequeModule

/// PPoG packets waiting for CoreBluetooth to drain its transmit queue.
///
/// Order is the whole point: the protocol numbers its packets, and one
/// overtaking another stalls the session until the watch times out. So once a
/// packet for a watch is waiting, every later packet for that watch waits too.
struct PendingNotificationQueue: Equatable, Sendable {
    private var packets: Deque<(centralID: String, value: Data)> = []

    var isEmpty: Bool {
        packets.isEmpty
    }

    var first: (centralID: String, value: Data)? {
        packets.first
    }

    /// Whether a packet for this watch has to join the queue rather than being
    /// sent straight away.
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
