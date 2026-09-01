import Foundation
import HTTPTypes
import Retry

extension RetryConfiguration where ClockType == ContinuousClock {
    /// Three attempts, half a second apart at first and no more than four apart,
    /// with jitter: the services behind this are public and shared.
    static var networkFetch: Self {
        RetryConfiguration(
            maxAttempts: 3,
            backoff: .default(baseDelay: .milliseconds(500), maxDelay: .seconds(4))
        )
    }
}

extension HTTPResponse.Status {
    /// A service that is overloaded, restarting or rate-limiting says so; one that
    /// has understood the request and refused it will refuse it again.
    var isWorthAnotherAttempt: Bool {
        kind == .serverError || self == .tooManyRequests || self == .requestTimeout
    }
}
