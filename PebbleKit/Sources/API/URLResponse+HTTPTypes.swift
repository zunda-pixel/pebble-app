import Foundation
import HTTPTypes
import HTTPTypesFoundation

extension URLResponse {
    /// The reply as typed HTTP, so callers compare statuses by name rather
    /// than by number.
    ///
    /// `URLSession`'s download and upload methods predate `HTTPRequest` and
    /// still hand back a `URLResponse`, so this is the one place that cast
    /// happens.
    var httpTypesResponse: HTTPResponse? {
        (self as? HTTPURLResponse)?.httpResponse
    }
}
