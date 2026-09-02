import PebbleProtocol
import Foundation

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
    private(set) var device: DiscoveredPebble?
    /// Whether the attempt in flight is the policy's own rather than a connect
    /// the reader asked for. The handshake takes a different path for each.
    private(set) var isAutomatic = false

    private var backoff = PebbleReconnectBackoff()
    private var scheduled: Task<Void, Never>?
    private var expectedDisconnects: Set<String> = []

    /// The watch to chase from now on, with the wait back at its shortest.
    func follow(_ device: DiscoveredPebble) {
        self.device = device
        isAutomatic = false
        backoff.reset()
    }

    /// Stops chasing: a disconnect the reader asked for, or a watch forgotten.
    /// The schedule goes with it, or the attempt it had queued would undo this.
    func stop() {
        cancelSchedule()
        device = nil
        isAutomatic = false
        backoff.reset()
    }

    func isFollowing(_ deviceID: String) -> Bool {
        device == nil || device?.id == deviceID
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
    func expectDisconnect(of identifier: String) {
        expectedDisconnects.insert(identifier)
    }

    /// Whether this disconnect was asked for. Consumed: a later drop of the same
    /// watch is the watch's doing, not the app's.
    func wasExpected(_ identifier: String) -> Bool {
        expectedDisconnects.remove(identifier) != nil
    }
}
