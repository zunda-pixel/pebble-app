import Foundation
import HTTPTypes
import HTTPTypesFoundation

enum HTTPFileDownloadError: Error, Equatable, Sendable {
    case insecureURL
    case invalidRequest
    case unsuccessfulReply(HTTPResponse.Status)

    /// A refused URL, or a request that could not be built at all, fails for good.
    var isWorthAnotherAttempt: Bool {
        switch self {
        case .insecureURL, .invalidRequest:
            false
        case .unsuccessfulReply(let status):
            status.isWorthAnotherAttempt
        }
    }
}

/// The body streams to disk rather than into memory, which keeps an oversized
/// reply from being buffered.
func downloadFile(
    from url: URL,
    using session: URLSession
) async throws -> URL {
    guard url.scheme?.lowercased() == "https" else {
        throw HTTPFileDownloadError.insecureURL
    }
    guard let request = URLRequest(httpRequest: HTTPRequest(method: .get, url: url)) else {
        throw HTTPFileDownloadError.invalidRequest
    }
    let (temporaryURL, response) = try await session.download(for: request)
    guard let status = (response as? HTTPURLResponse)?.httpResponse?.status else {
        throw HTTPFileDownloadError.invalidRequest
    }
    guard status == .ok else {
        throw HTTPFileDownloadError.unsuccessfulReply(status)
    }
    return temporaryURL
}
