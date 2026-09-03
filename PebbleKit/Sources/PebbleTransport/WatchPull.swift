import PebbleProtocol

/// One thing the app asks the watch to hand over: a screenshot, a generation of
/// logs, a file off its flash.
///
/// The three were written out separately — a collector, a reply, and a finish
/// that clears the collector, each — and the deadline is what makes them worth
/// having in one place. A coredump is a hundred kilobytes over a link that
/// manages a few of them a second, so what is timed is the watch going quiet
/// rather than the whole transfer, which means every piece that arrives has to
/// remember to put the deadline back.
@MainActor
final class WatchPull<Collector: WatchPullCollector> {
    private let timeout: Duration
    private let reply: PendingReply<Collector.Value>
    private var collector: Collector?

    init(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.timeout = timeout
        reply = PendingReply(sleep: sleep)
    }

    var isInProgress: Bool {
        collector != nil
    }

    /// Asks, then waits for the watch to finish answering.
    func run(
        collecting collector: Collector,
        send: () throws -> Void
    ) async throws -> Collector.Value {
        guard self.collector == nil, !reply.isWaiting else {
            throw WatchPullError.operationAlreadyInProgress
        }
        self.collector = collector
        return try await reply.wait(timeout: timeout, send: send)
    }

    /// Takes a frame belonging to a pull in progress, and says whether it did: a
    /// watch still answering a request the app has given up on is not an error,
    /// but the frame is nobody's.
    func take(_ frame: PebbleProtocolFrame) -> Bool {
        guard isInProgress else { return false }
        do {
            if let value = try collector?.accept(frame) {
                finish(.success(value))
            } else {
                reply.extendDeadline(timeout)
            }
        } catch {
            finish(.failure(error))
        }
        return true
    }

    func finish(_ result: Result<Collector.Value, any Error>) {
        collector = nil
        reply.resume(with: result)
    }
}
