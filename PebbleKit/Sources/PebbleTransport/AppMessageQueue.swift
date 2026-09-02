import PebbleProtocol
import DequeModule
import Foundation

/// The app messages waiting for a watch, one at a time.
///
/// The watch acknowledges by transaction id, so only one may be outstanding;
/// what queues up behind it is the reason this is a type rather than five
/// properties on the client. It knows nothing about CoreBluetooth — it is handed
/// a way to put one message on the wire, and reports the answer back to whoever
/// is awaiting it.
@MainActor
final class AppMessageQueue {
    private struct Pending {
        var applicationID: UUID
        var tuples: [AppMessageTuple]
        var continuation: CheckedContinuation<Void, any Error>
    }

    /// Puts one message on the wire. Throwing means the link is not there, which
    /// fails that message rather than the queue.
    var send: (@MainActor (AppMessageData) throws -> Void)?

    private let timeout: Duration
    private var queued: Deque<Pending> = []
    private var active: Pending?
    private var activeTransactionID: UInt8?
    private var nextTransactionID: UInt8 = 0
    private var deadline: Task<Void, Never>?

    init(timeout: Duration = .seconds(10)) {
        self.timeout = timeout
    }

    /// The transaction the watch owes an answer for, so an acknowledgement for
    /// something else can be ignored.
    var outstandingTransactionID: UInt8? {
        activeTransactionID
    }

    var isEmpty: Bool {
        active == nil && queued.isEmpty
    }

    func enqueue(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queued.append(Pending(
                applicationID: applicationID,
                tuples: tuples,
                continuation: continuation
            ))
            startNextIfPossible()
        }
    }

    func startNextIfPossible() {
        guard active == nil, let next = queued.first, let send else { return }
        queued.removeFirst()
        let transactionID = nextTransactionID
        nextTransactionID &+= 1
        active = next
        activeTransactionID = transactionID
        do {
            try send(AppMessageData(
                transactionID: transactionID,
                applicationID: next.applicationID,
                tuples: next.tuples
            ))
            deadline?.cancel()
            deadline = Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishActive(throwing: PebbleConnectionError.connectionTimedOut)
            }
        } catch {
            finishActive(throwing: error)
        }
    }

    func finishActive(throwing error: (any Error)? = nil) {
        deadline?.cancel()
        deadline = nil
        let finished = active
        active = nil
        activeTransactionID = nil
        if let error {
            finished?.continuation.resume(throwing: error)
        } else {
            finished?.continuation.resume()
        }
        startNextIfPossible()
    }

    /// The link is gone: what was in flight is over, and so is everything behind
    /// it. `AppModel` keeps its own list of undelivered messages and flushes that
    /// on the next connection, so a copy held here would be sent twice.
    func failAll(_ error: any Error) {
        deadline?.cancel()
        deadline = nil
        active?.continuation.resume(throwing: error)
        active = nil
        activeTransactionID = nil
        let waiting = queued
        queued.removeAll()
        for message in waiting {
            message.continuation.resume(throwing: error)
        }
    }
}
