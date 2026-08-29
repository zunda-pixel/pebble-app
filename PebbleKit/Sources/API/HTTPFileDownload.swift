import Foundation
import HTTPTypes
import HTTPTypesFoundation

enum HTTPFileDownloadError: Error, Equatable, Sendable {
    case insecureURL
    case unsuccessfulReply
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
        throw HTTPFileDownloadError.unsuccessfulReply
    }
    let (temporaryURL, response) = try await session.download(for: request)
    guard (response as? HTTPURLResponse)?.httpResponse?.status == .ok else {
        throw HTTPFileDownloadError.unsuccessfulReply
    }
    return temporaryURL
}
