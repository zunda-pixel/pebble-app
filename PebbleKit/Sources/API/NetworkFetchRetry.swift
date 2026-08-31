import Foundation
import HTTPTypes
import Retry

extension RetryConfiguration where ClockType == ContinuousClock {
    /// How a request to a web service is retried.
    ///
    /// Three attempts, half a second apart at first and no more than four
    /// seconds apart, with jitter — the services here are shared, and a fleet
    /// of clients that all retry on the same schedule is how a service that is
    /// merely busy is knocked over.
    ///
    /// Everything is retried unless the code that failed says otherwise by
    /// throwing `NotRetryable`, which is what a refused URL and a reply that
    /// will read the same next time do.
    static var networkFetch: Self {
        RetryConfiguration(
            maxAttempts: 3,
            backoff: .default(baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        )
    }
}

extension HTTPResponse.Status {
    /// Whether sending the same request again could get a different answer.
    /// A service that is overloaded, restarting or rate-limiting says so; a
    /// service that has understood the request and refused it will refuse it
    /// again.
    var isWorthAnotherAttempt: Bool {
        kind == .serverError || self == .tooManyRequests || self == .requestTimeout
    }
}
