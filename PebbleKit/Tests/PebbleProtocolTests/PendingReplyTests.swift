import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// The one request-and-answer state machine the Bluetooth client used to write
/// out by hand for each of its seven operations.
@Suite
@MainActor
struct PendingReplyTests {
    @Test
    func anAnswerFromTheWatchResumesTheCaller() async throws {
        let reply = PendingReply<Int>()
        let waiting = Task { try await reply.wait(timeout: .seconds(5)) {} }
        while !reply.isWaiting { await Task.yield() }

        reply.finish(42)

        #expect(try await waiting.value == 42)
        #expect(!reply.isWaiting)
    }

    @Test
    func aRequestThatIsNeverAnsweredGivesUpOnItsDeadline() async throws {
        let reply = PendingReply<Int>()

        await #expect(throws: WatchConnectionError.connectionTimedOut) {
            try await reply.wait(timeout: .milliseconds(20)) {}
        }
        #expect(!reply.isWaiting)
    }

    @Test
    func aRequestThatCannotBeSentFailsWithoutWaiting() async {
        let reply = PendingReply<Int>()

        await #expect(throws: WatchConnectionError.disconnected) {
            try await reply.wait(timeout: .seconds(60)) {
                throw WatchConnectionError.disconnected
            }
        }
        // Nothing is left holding the deadline, so a later request is free to
        // start.
        #expect(!reply.isWaiting)
    }

    @Test
    func aSecondAnswerIsIgnoredRatherThanResumingTwice() async throws {
        let reply = PendingReply<Int>()
        let waiting = Task { try await reply.wait(timeout: .seconds(5)) {} }
        while !reply.isWaiting { await Task.yield() }

        reply.finish(1)
        // The watch repeating itself, or a deadline firing after the answer, must
        // not resume a continuation that has already been used: that is a crash,
        // not an error.
        reply.finish(2)
        reply.fail(WatchConnectionError.disconnected)

        #expect(try await waiting.value == 1)
    }

    @Test
    func aDeadlineThatWasPutBackDoesNotComeDueBehindTheOneThatReplacedIt() async throws {
        let deadlines = HeldDeadlines()
        let reply = PendingReply<Int>(sleep: { _ in await deadlines.hold() })
        let waiting = Task { try await reply.wait(timeout: .milliseconds(60)) {} }
        while !reply.isWaiting { await Task.yield() }
        await deadlines.waitUntilHolding(1)

        // A coredump arrives over a minute, and each chunk puts the deadline
        // back. The first one still comes due at its own hour — it has to find
        // that it has been replaced and say nothing.
        reply.extendDeadline(.milliseconds(60))
        await deadlines.waitUntilHolding(2)
        await deadlines.releaseFirst()
        await Task.yield()

        #expect(reply.isWaiting)

        reply.finish(7)
        #expect(try await waiting.value == 7)
        await deadlines.releaseAll()
    }

    @Test
    func theDeadlineLeftStandingIsTheOneThatFires() async throws {
        let deadlines = HeldDeadlines()
        let reply = PendingReply<Int>(sleep: { _ in await deadlines.hold() })
        let waiting = Task { try await reply.wait(timeout: .seconds(60)) {} }
        while !reply.isWaiting { await Task.yield() }
        reply.extendDeadline(.seconds(60))

        // The one that was replaced comes due at the same moment as the one
        // that replaced it, and only the second may be heard from.
        await deadlines.waitUntilHolding(2)
        await deadlines.releaseAll()

        await #expect(throws: WatchConnectionError.connectionTimedOut) {
            try await waiting.value
        }
    }

    @Test
    func aLinkThatGoesFailsTheCallerWithItsOwnError() async throws {
        let reply = PendingReply<Int>()
        let waiting = Task { try await reply.wait(timeout: .seconds(5)) {} }
        while !reply.isWaiting { await Task.yield() }

        reply.fail(WatchConnectionError.disconnected)

        await #expect(throws: WatchConnectionError.disconnected) {
            try await waiting.value
        }
    }
}

/// Deadlines that fall due when the test says so.
///
/// A deadline measured in real time is a race between the test and the
/// scheduler, and this one lost it about once in a hundred runs on a machine
/// that was also compiling.
private actor HeldDeadlines {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var expected: (count: Int, arrived: CheckedContinuation<Void, Never>)?

    func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            guard let expected, held.count >= expected.count else { return }
            self.expected = nil
            expected.arrived.resume()
        }
    }

    /// Waits until that many deadlines are holding.
    ///
    /// Releasing before they arrive releases nothing: the deadline runs in a
    /// task of its own, which need not have reached its first suspension when
    /// the line that started it returns. That left one test asserting nothing
    /// and the other waiting for an answer that nobody was going to give.
    func waitUntilHolding(_ count: Int) async {
        guard held.count < count else { return }
        await withCheckedContinuation { expected = (count, $0) }
    }

    /// Lets the oldest deadline come due while the ones after it keep waiting.
    func releaseFirst() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func releaseAll() {
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }
}
