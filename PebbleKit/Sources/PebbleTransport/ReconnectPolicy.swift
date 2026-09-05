import PebbleProtocol
import CoreBluetooth
import Foundation

extension CBPeripheral {
    /// How this phone names the watch behind this peripheral.
    ///
    /// CoreBluetooth's identifier is per host rather than the watch's own, which
    /// is exactly what a `WatchID` is — so this is the one place the conversion
    /// happens, rather than `identifier.uuidString` at thirty call sites.
    /// `PebbleGattServer` keys by the same string under its own name, because
    /// there a watch is a central.
    var watchID: WatchID {
        WatchID(identifier.uuidString)
    }
}

struct PebbleReconnectBackoff: Equatable, Sendable {
    var attempt: Int = 0
    var initialDelay: Duration = .seconds(2)
    var maximumDelay: Duration = .seconds(30)

    mutating func nextDelay() -> Duration {
        let multiplier = 1 << min(attempt, 10)
        let delay = min(initialDelay * multiplier, maximumDelay)
        attempt = min(attempt + 1, 10)
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}

/// Whether a watch that dropped should be chased, and how long to wait before
/// each attempt.
///
/// The attempt itself belongs to the client — only it can ask CoreBluetooth to
/// connect — but which watch is being followed, how long the wait has grown to,
/// whether the current attempt is the app's own idea, and which disconnects were
/// asked for are all bookkeeping, and keeping them together is what stops one of
/// them being cleared without the others. A manual disconnect that left the
/// schedule armed used to undo itself a second later.
@MainActor
final class ReconnectPolicy {
    /// How many links may come up and die in the handshake before the app stops
    /// chasing. With the backoff below that is about a minute of trying, which
    /// covers a watch that is merely restarting.
    static let maximumFailedHandshakes = 5

    private(set) var watch: DiscoveredWatch?
    /// Whether the attempt in flight is the policy's own rather than a connect
    /// the reader asked for. The handshake takes a different path for each.
    private(set) var isAutomatic = false
    private(set) var failedHandshakes = 0

    private var backoff = PebbleReconnectBackoff()
    private var scheduled: Task<Void, Never>?
    private var expectedDisconnects: Set<WatchID> = []

    /// The watch to chase from now on, with the wait back at its shortest.
    func follow(_ watch: DiscoveredWatch) {
        self.watch = watch
        isAutomatic = false
        backoff.reset()
        failedHandshakes = 0
    }

    /// Stops chasing: a disconnect the reader asked for, or a watch forgotten.
    /// The schedule goes with it, or the attempt it had queued would undo this.
    func stop() {
        cancelSchedule()
        watch = nil
        isAutomatic = false
        backoff.reset()
        failedHandshakes = 0
    }

    /// A link that came up and then dropped without a session. False when that
    /// has happened often enough to stop.
    ///
    /// The backoff cannot decide this: it counts attempts, and the connect
    /// itself succeeded every time — a watch whose protocol service was unusable
    /// went round this loop every thirty seconds for six minutes, saying
    /// "Reconnecting…" and nothing else.
    func noteHandshakeFailed() -> Bool {
        failedHandshakes += 1
        return failedHandshakes < Self.maximumFailedHandshakes
    }

    func isFollowing(_ watchID: WatchID) -> Bool {
        watch == nil || watch?.id == watchID
    }

    func beginAutomaticAttempt() {
        isAutomatic = true
    }

    /// Waits out the next delay and then runs `attempt`, replacing any attempt
    /// already queued.
    @discardableResult
    func schedule(_ attempt: @escaping @MainActor () -> Void) -> Duration {
        let delay = backoff.nextDelay()
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            attempt()
        }
        return delay
    }

    func cancelSchedule() {
        scheduled?.cancel()
        scheduled = nil
    }

    /// Records that this link is about to be dropped on purpose, so the
    /// disconnect it produces is not chased. A locally cancelled link arrives
    /// back as a disconnect with no error, which is otherwise indistinguishable
    /// from the watch walking away.
    func expectDisconnect(of identifier: WatchID) {
        expectedDisconnects.insert(identifier)
    }

    /// Whether this disconnect was asked for. Consumed: a later drop of the same
    /// watch is the watch's doing, not the app's.
    func wasExpected(_ identifier: WatchID) -> Bool {
        expectedDisconnects.remove(identifier) != nil
    }
}
