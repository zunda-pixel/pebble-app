import PebbleProtocol
import Retry

extension RetryConfiguration where ClockType == ContinuousClock {
    /// Three attempts a few hundred milliseconds apart, growing to at most two
    /// seconds: long enough to ride out a watch busy with something else, short
    /// enough that a reader is not left waiting.
    static var watchWork: Self {
        RetryConfiguration(
            maxAttempts: 3,
            backoff: .default(baseDelay: .milliseconds(250), maxDelay: .seconds(2)),
            recoverFromFailure: { error in
                if error is CancellationError { return .throw }
                if let error = error as? WatchConnectionError, !error.isWorthAnotherAttempt {
                    return .throw
                }
                if let error = error as? BlobDBClientError,
                   case .rejected(let status) = error,
                   !status.isWorthAnotherAttempt {
                    return .throw
                }
                return .retry
            }
        )
    }
}

extension BlobDBStatus {
    /// Only a watch that is busy answers differently a moment later. Full,
    /// unsupported or malformed is the same answer on the third try, and each
    /// try is another write the watch has to refuse.
    var isWorthAnotherAttempt: Bool {
        switch self {
        case .tryLater, .locked: true
        default: false
        }
    }
}
