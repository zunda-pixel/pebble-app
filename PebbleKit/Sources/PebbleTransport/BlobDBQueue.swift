import PebbleProtocol
import DequeModule
import Foundation

/// Whose turn it is to write to one of the watch's databases.
///
/// The watch answers a BlobDB write by token and keeps one outstanding, so the
/// client can only have one in flight. Turning the second caller away is what it
/// did before, and the callers are unrelated features on unrelated timers — the
/// weather screen reported that the watch had refused a list of places when all
/// that had happened was that the app was still writing its apps and settings
/// from the connection a few seconds earlier. They queue instead, in the order
/// they asked, which is also the order two of them need: the watch drops a
/// forecast whose place it has no ordering for.
@MainActor
final class BlobDBQueue {
    private var isBusy = false
    private var waiting: Deque<CheckedContinuation<Void, any Error>> = []

    /// Whether a write holds the queue right now.
    var isEngaged: Bool {
        isBusy
    }

    var numberWaiting: Int {
        waiting.count
    }

    /// Waits for this caller's turn. Returns holding it, so every path out of
    /// the caller has to `finish`.
    func begin() async throws {
        guard isBusy else {
            isBusy = true
            return
        }
        try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    /// Hands the turn to whoever is next, or lets the queue go idle.
    func finish() {
        guard let next = waiting.popFirst() else {
            isBusy = false
            return
        }
        next.resume()
    }

    /// The link is gone: nobody's turn is coming. Whoever holds it is failed by
    /// the reply they are waiting on; these never got that far.
    ///
    /// The turn itself is left with its holder — their `finish` is what
    /// releases it. Declaring the queue free here let a new caller in while
    /// the failed holder was still unwinding, and the holder's own `finish`
    /// then released the newcomer's turn to a third.
    func failAll(_ error: any Error) {
        let queued = waiting
        waiting.removeAll()
        for continuation in queued {
            continuation.resume(throwing: error)
        }
    }
}
