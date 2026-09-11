import PebbleProtocol
import Foundation

/// One request to the watch that is answered later, with the deadline that gives
/// up on it.
///
/// Seven of these were written out by hand in the Bluetooth client — a
/// continuation property, a timeout task property, and a finish/fail pair each —
/// and every copy was somewhere to forget the guard against a second caller, to
/// leave a deadline running after the answer arrived, or to resume nothing when
/// the link went. The invariants live here once instead: a reply is waited on by
/// one caller at a time, the deadline is cancelled by whichever of the two
/// arrives first, and resuming twice is impossible because the continuation is
/// taken before it is used.
@MainActor
final class PendingReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var deadline: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async -> Void

    /// How the deadline waits. Real time, except in a test, which would rather
    /// say when the deadline falls due than race it: a machine busy compiling
    /// can be slower than any margin worth writing down.
    init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    var isWaiting: Bool {
        continuation != nil
    }

    /// Sends the request and waits for the watch.
    ///
    /// `send` runs with the continuation already stored, because the answer can
    /// arrive before it returns — the watch is fast and the frame handler is on
    /// this same actor.
    func wait(
        timeout: Duration,
        timedOut: any Error = WatchConnectionError.connectionTimedOut,
        send: () throws -> Void
    ) async throws -> Value {
        // A second waiter would silently overwrite the first continuation,
        // whose caller then hangs for the life of the process — the callers
        // are supposed to be serialized upstream, and a broken queue should
        // read as this error, not as a hang.
        guard continuation == nil else {
            throw WatchConnectionError.connectionAlreadyInProgress
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            do {
                try send()
                extendDeadline(timeout, timedOut: timedOut)
            } catch {
                fail(error)
            }
        }
    }

    /// Puts the deadline back for an answer that arrives in pieces: the watch
    /// sends a coredump over a minute or more, and each chunk is proof that it is
    /// still there. Measuring silence rather than the whole transfer is what
    /// keeps a large but healthy one from being cut off.
    func extendDeadline(
        _ timeout: Duration,
        timedOut: any Error = WatchConnectionError.connectionTimedOut
    ) {
        deadline?.cancel()
        deadline = Task { [weak self, sleep] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.fail(timedOut)
        }
    }

    func finish(_ value: Value) {
        resume { $0.resume(returning: value) }
    }

    func fail(_ error: any Error) {
        resume { $0.resume(throwing: error) }
    }

    func resume(with result: Result<Value, any Error>) {
        resume { $0.resume(with: result) }
    }

    /// Whatever the watch was in the middle of answering is over, and nobody is
    /// waiting on it any more.
    func cancelDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    private func resume(_ body: (CheckedContinuation<Value, any Error>) -> Void) {
        cancelDeadline()
        guard let continuation else { return }
        self.continuation = nil
        body(continuation)
    }
}

extension PendingReply where Value == Void {
    func finish() {
        finish(())
    }
}
