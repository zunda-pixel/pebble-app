import Foundation
import HTTPTypes
import HTTPTypesFoundation

enum HTTPFileDownloadError: Error, Equatable, Sendable {
    case insecureURL
    case invalidRequest
    case unsuccessfulReply(HTTPResponse.Status)

    /// Whether asking again could get the file. The status the service gave is
    /// what decides it; a refused URL, or a request that could not be built at
    /// all, fails the same way every time.
    var isWorthAnotherAttempt: Bool {
        switch self {
        case .insecureURL, .invalidRequest:
            false
        case .unsuccessfulReply(let status):
            status.isWorthAnotherAttempt
        }
    }
}

/// Fetches a file over HTTPS into a temporary location.
///
/// The body streams to disk rather than into memory, which is what keeps an
/// oversized reply from being buffered — so this uses `URLSession.download`,
/// which has no `HTTPRequest` form. Bridging the typed request and reading the
/// reply's status therefore happens here, once, for every caller.
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
