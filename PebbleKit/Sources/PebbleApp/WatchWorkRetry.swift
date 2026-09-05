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
                if let error = error as? WatchConnectionError, !error.isWorthAnotherAttempt {
                    return .throw
                }
                return .retry
            }
        )
    }
}
