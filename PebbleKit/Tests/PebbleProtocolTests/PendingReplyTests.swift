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

        await #expect(throws: PebbleConnectionError.connectionTimedOut) {
            try await reply.wait(timeout: .milliseconds(20)) {}
        }
        #expect(!reply.isWaiting)
    }

    @Test
    func aRequestThatCannotBeSentFailsWithoutWaiting() async {
        let reply = PendingReply<Int>()

        await #expect(throws: PebbleConnectionError.disconnected) {
            try await reply.wait(timeout: .seconds(60)) {
                throw PebbleConnectionError.disconnected
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
        reply.fail(PebbleConnectionError.disconnected)

        #expect(try await waiting.value == 1)
    }

    @Test
    func eachChunkPutsTheDeadlineBack() async throws {
        let reply = PendingReply<Int>()
        let waiting = Task { try await reply.wait(timeout: .milliseconds(60)) {} }
        while !reply.isWaiting { await Task.yield() }

        // A coredump arrives over a minute; only silence means the watch has
        // stopped, so an answer in pieces has to be able to outlive one deadline.
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(40))
            reply.extendDeadline(.milliseconds(60))
        }
        reply.finish(7)

        #expect(try await waiting.value == 7)
    }

    @Test
    func aLinkThatGoesFailsTheCallerWithItsOwnError() async throws {
        let reply = PendingReply<Int>()
        let waiting = Task { try await reply.wait(timeout: .seconds(5)) {} }
        while !reply.isWaiting { await Task.yield() }

        reply.fail(PebbleConnectionError.disconnected)

        await #expect(throws: PebbleConnectionError.disconnected) {
            try await waiting.value
        }
    }
}
