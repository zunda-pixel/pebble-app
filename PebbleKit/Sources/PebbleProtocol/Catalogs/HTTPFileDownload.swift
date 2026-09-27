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
    let temporaryURL: URL
    let response: HTTPResponse
    do {
        (temporaryURL, response) = try await session.httpsDownload(for: HTTPRequest(method: .get, url: url))
    } catch is InsecureURLError {
        throw HTTPFileDownloadError.insecureURL
    }
    guard response.status == .ok else {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw HTTPFileDownloadError.unsuccessfulReply(response.status)
    }
    return temporaryURL
}

func downloadedFileSize(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.intValue ?? 0
}
