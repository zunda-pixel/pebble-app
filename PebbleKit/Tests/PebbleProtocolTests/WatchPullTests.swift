import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// The three things the app takes off the watch — a screenshot, a generation of
/// logs, a file — which arrive in pieces and used to be waited for by three
/// hand-written copies of this.
@Suite
@MainActor
struct WatchPullTests {
    @Test
    func theLastPieceHandsTheWholeThingBack() async throws {
        let pull = WatchPull<CountingCollector>(timeout: .seconds(30))
        var sent = false
        let waiting = Task {
            try await pull.run(collecting: CountingCollector(total: 3)) { sent = true }
        }
        while !pull.isInProgress { await Task.yield() }
        #expect(sent)

        #expect(pull.take(piece([1])))
        #expect(pull.take(piece([2])))
        #expect(pull.take(piece([3])))

        #expect(try await waiting.value == [1, 2, 3])
        #expect(!pull.isInProgress)
    }

    @Test
    func aSecondCallerIsTurnedAwayWhileTheFirstIsWaiting() async throws {
        let pull = WatchPull<CountingCollector>(timeout: .seconds(30))
        let waiting = Task { try await pull.run(collecting: CountingCollector(total: 1)) {} }
        while !pull.isInProgress { await Task.yield() }

        await #expect(throws: WatchPullError.operationAlreadyInProgress) {
            try await pull.run(collecting: CountingCollector(total: 1)) {}
        }

        _ = pull.take(piece([1]))
        _ = try await waiting.value
    }

    @Test
    func aFrameArrivingWithNoPullInProgressIsLeftAlone() {
        let pull = WatchPull<CountingCollector>(timeout: .seconds(30))

        // The watch finishing an answer the app has already given up on is not
        // an error, but the frame belongs to nobody and the caller of `take`
        // has to be able to tell.
        #expect(!pull.take(piece([1])))
    }

    @Test
    func aPieceThatCannotBeReadFailsTheCaller() async throws {
        let pull = WatchPull<CountingCollector>(timeout: .seconds(30))
        let waiting = Task { try await pull.run(collecting: CountingCollector(total: 3)) {} }
        while !pull.isInProgress { await Task.yield() }

        #expect(pull.take(piece([])))

        await #expect(throws: CountingError.refused) { try await waiting.value }
        // Nothing is left half-collected, so the next pull starts from scratch.
        #expect(!pull.isInProgress)
    }

    @Test
    func aLinkThatGoesFailsThePullInProgress() async throws {
        let pull = WatchPull<CountingCollector>(timeout: .seconds(30))
        let waiting = Task { try await pull.run(collecting: CountingCollector(total: 3)) {} }
        while !pull.isInProgress { await Task.yield() }
        _ = pull.take(piece([1]))

        pull.finish(.failure(PebbleConnectionError.disconnected))

        await #expect(throws: PebbleConnectionError.disconnected) { try await waiting.value }
        #expect(!pull.isInProgress)
    }

    @Test
    func everyPieceThatArrivesPutsTheDeadlineBack() async throws {
        let deadlines = DeadlineLog()
        let pull = WatchPull<CountingCollector>(
            timeout: .seconds(30),
            sleep: { duration in
                await deadlines.note()
                try? await Task.sleep(for: duration)
            }
        )
        let waiting = Task { try await pull.run(collecting: CountingCollector(total: 3)) {} }
        while !pull.isInProgress { await Task.yield() }
        #expect(await deadlines.reached(1))

        // A coredump arrives over a minute. Each piece is proof the watch is
        // still there, so the deadline starts again from it rather than from the
        // request — measuring the whole transfer would cut off a large but
        // healthy one.
        _ = pull.take(piece([1]))
        #expect(await deadlines.reached(2))
        _ = pull.take(piece([2]))
        #expect(await deadlines.reached(3))

        _ = pull.take(piece([3]))
        #expect(try await waiting.value == [1, 2, 3])
    }

    private func piece(_ payload: [UInt8]) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: CountingCollector.endpoint, payload: payload)
    }
}

private enum CountingError: Error, Equatable {
    case refused
}

/// Gathers a fixed number of bytes the way the watch's own collectors do:
/// `nil` until the last piece lands.
private struct CountingCollector: WatchPullCollector {
    static var endpoint: UInt16 { 9_999 }

    let total: Int
    private var received: [UInt8] = []

    init(total: Int) {
        self.total = total
    }

    mutating func accept(_ frame: PebbleProtocolFrame) throws -> [UInt8]? {
        guard !frame.payload.isEmpty else { throw CountingError.refused }
        received += frame.payload
        return received.count >= total ? received : nil
    }
}

/// Counts the deadlines a pull asks for, so a test can say that a piece put one
/// back without racing a real one.
private actor DeadlineLog {
    private var count = 0

    func note() {
        count += 1
    }

    /// Whether that many deadlines were asked for, given the chance to arrive:
    /// the task that holds one need not have reached its first suspension when
    /// the line that started it returns.
    func reached(_ target: Int) async -> Bool {
        for _ in 0..<10_000 {
            if count >= target { return true }
            await Task.yield()
        }
        return false
    }
}
