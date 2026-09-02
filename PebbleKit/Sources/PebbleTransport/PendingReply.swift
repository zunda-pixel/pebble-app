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
        timedOut: any Error = PebbleConnectionError.connectionTimedOut,
        send: () throws -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
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
        timedOut: any Error = PebbleConnectionError.connectionTimedOut
    ) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
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
