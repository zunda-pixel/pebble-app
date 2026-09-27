import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// Whose turn it is to write to one of the watch's databases.
@Suite
@MainActor
struct BlobDBQueueTests {
    @Test
    func theFirstCallerGetsTheTurnWithoutWaiting() async throws {
        let queue = BlobDBQueue()

        try await queue.begin()

        #expect(queue.isEngaged)
        #expect(queue.numberWaiting == 0)
    }

    @Test
    func asecondCallerWaitsInsteadOfBeingRefused() async throws {
        // The weather screen used to report that the watch had refused a list of
        // places when all that had happened was that the app was still writing
        // its apps and settings from a connection seconds earlier.
        let queue = BlobDBQueue()
        try await queue.begin()

        let second = Task { try await queue.begin() }
        while queue.numberWaiting == 0 { await Task.yield() }

        #expect(!second.isCancelled)
        queue.finish()

        try await second.value
        #expect(queue.isEngaged)
    }

    @Test
    func turnsAreGivenOutInTheOrderTheyWereAskedFor() async throws {
        // The watch drops a forecast whose place it has no ordering for, so the
        // order the writes were asked in is the order they have to go out in.
        let queue = BlobDBQueue()
        let order = Order()
        try await queue.begin()

        let waiting = (1...3).map { position in
            Task {
                try await queue.begin()
                await order.append(position)
            }
        }
        while queue.numberWaiting < 3 { await Task.yield() }

        for _ in 0..<4 {
            queue.finish()
            await Task.yield()
        }
        for task in waiting {
            try await task.value
        }

        #expect(await order.positions == [1, 2, 3])
    }

    @Test
    func aWriteThatFailsStillHandsTheTurnOn() async throws {
        let queue = BlobDBQueue()
        try await queue.begin()

        let second = Task { try await queue.begin() }
        while queue.numberWaiting == 0 { await Task.yield() }
        // What the caller's `defer` does whether its write was answered, refused
        // or never sent.
        queue.finish()

        try await second.value
        queue.finish()
        #expect(!queue.isEngaged)
    }

    @Test
    func aLinkThatGoesFailsEveryoneStillWaiting() async throws {
        let queue = BlobDBQueue()
        try await queue.begin()
        let second = Task { try await queue.begin() }
        while queue.numberWaiting == 0 { await Task.yield() }

        queue.failAll(WatchConnectionError.disconnected)

        await #expect(throws: WatchConnectionError.disconnected) {
            try await second.value
        }
        // The turn stays with its holder — the holder's own `finish` is what
        // frees it. Freed here, a new caller could take the queue while the
        // failed holder was still unwinding, and the holder's `finish` then
        // handed the newcomer's turn to a third.
        #expect(queue.isEngaged)
        queue.finish()
        #expect(!queue.isEngaged)
    }
}

private actor Order {
    private(set) var positions: [Int] = []

    func append(_ position: Int) {
        positions.append(position)
    }
}
