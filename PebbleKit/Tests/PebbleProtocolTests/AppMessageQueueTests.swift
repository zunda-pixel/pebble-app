import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// The queue that holds app messages for a watch that answers one at a time.
@Suite
@MainActor
struct AppMessageQueueTests {
    private func tuples(_ value: Int32) -> [AppMessageTuple] {
        [AppMessageTuple(key: 1, value: .signed(value))]
    }

    @Test
    func messagesGoOutOneAtATimeAndInOrder() async throws {
        let queue = AppMessageQueue()
        var sent: [AppMessageData] = []
        queue.send = { sent.append($0) }

        let first = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(1)) }
        let second = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(2)) }
        while sent.isEmpty { await Task.yield() }

        // The watch answers by transaction id, so only one may be outstanding.
        #expect(sent.count == 1)
        let firstTransactionID = try #require(queue.outstandingTransactionID)
        queue.finishActive()
        try await first.value

        while sent.count < 2 { await Task.yield() }
        #expect(queue.outstandingTransactionID == firstTransactionID &+ 1)
        queue.finishActive()
        try await second.value
        #expect(queue.isEmpty)
    }

    @Test
    func aRefusedMessageFailsOnlyItself() async throws {
        let queue = AppMessageQueue()
        var sent: [AppMessageData] = []
        queue.send = { sent.append($0) }

        let refused = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(1)) }
        while sent.isEmpty { await Task.yield() }
        queue.finishActive(throwing: AppMessageClientError.negativeAcknowledgement)

        await #expect(throws: AppMessageClientError.negativeAcknowledgement) {
            try await refused.value
        }

        // The next one still gets its turn.
        let accepted = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(2)) }
        while sent.count < 2 { await Task.yield() }
        queue.finishActive()
        try await accepted.value
    }

    @Test
    func aMessageThatIsNeverAnsweredGivesUpOnItsDeadline() async throws {
        let queue = AppMessageQueue(timeout: .milliseconds(20))
        queue.send = { _ in }

        await #expect(throws: WatchConnectionError.connectionTimedOut) {
            try await queue.enqueue(applicationID: UUID(), tuples: tuples(1))
        }
        #expect(queue.isEmpty)
    }

    @Test
    func aLinkThatGoesFailsEveryoneWaiting() async throws {
        let queue = AppMessageQueue()
        var sent: [AppMessageData] = []
        queue.send = { sent.append($0) }

        let inFlight = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(1)) }
        let waiting = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(2)) }
        while sent.isEmpty { await Task.yield() }

        queue.failAll(WatchConnectionError.disconnected)

        // Both callers hear about it: one whose message was in flight and one
        // whose turn never came. Leaving either suspended is what left a caller
        // waiting for a link that never came back.
        await #expect(throws: WatchConnectionError.disconnected) { try await inFlight.value }
        await #expect(throws: WatchConnectionError.disconnected) { try await waiting.value }
        #expect(queue.isEmpty)
    }

    @Test
    func nothingIsSentWhileThereIsNoLink() async throws {
        let queue = AppMessageQueue()
        let waiting = Task { try await queue.enqueue(applicationID: UUID(), tuples: tuples(1)) }
        try await Task.sleep(for: .milliseconds(20))

        // No sender yet: the message waits rather than failing, which is what
        // lets a queued message survive until the watch is back.
        #expect(!queue.isEmpty)
        #expect(queue.outstandingTransactionID == nil)

        var sent: [AppMessageData] = []
        queue.send = { sent.append($0) }
        queue.startNextIfPossible()
        while sent.isEmpty { await Task.yield() }
        queue.finishActive()
        try await waiting.value
    }
}
