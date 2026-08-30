import API
import Retry

extension RetryConfiguration where ClockType == ContinuousClock {
    /// How a request sent to a watch is retried.
    ///
    /// Three attempts, a few hundred milliseconds apart, growing to at most two
    /// seconds — long enough to ride out a busy radio, short enough that the
    /// reader is not left watching a spinner. The delays carry jitter, so two
    /// watches that fail at the same moment do not come back in step.
    ///
    /// An error that says the link is gone, or that Bluetooth is not available,
    /// is thrown straight away: the caller queues the work for the next
    /// connection, which is a better answer than sleeping first.
    static var watchWork: Self {
        RetryConfiguration(
            maxAttempts: 3,
            backoff: .default(baseDelay: .milliseconds(250), maxDelay: .seconds(2)),
            recoverFromFailure: { error in
                if let error = error as? PebbleConnectionError, !error.isWorthAnotherAttempt {
                    return .throw
                }
                return .retry
            }
        )
    }
}
