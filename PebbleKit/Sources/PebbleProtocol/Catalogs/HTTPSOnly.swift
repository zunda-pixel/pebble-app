package import Foundation
package import HTTPTypes
import HTTPTypesFoundation

/// A fetch of the app's own that was not https, asked for or redirected to.
package struct InsecureURLError: Error, Equatable, Sendable {
    package init() {}
}

extension URL {
    package var isHTTPS: Bool { scheme?.lowercased() == "https" }
}

/// Every request the app makes for itself goes through these. A PebbleKit JS
/// script's requests travel through `URLSession`, and App Transport Security
/// cannot be scoped to one session, so ATS is not what keeps the catalogue,
/// the firmware and the language packs on https — this is.
extension URLSession {
    package func httpsData(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
        guard request.scheme?.lowercased() == "https" else { throw InsecureURLError() }
        return try await data(for: request, delegate: HTTPSRedirectsOnly.shared)
    }

    package func httpsUpload(for request: HTTPRequest, from body: Data) async throws -> (Data, HTTPResponse) {
        guard request.scheme?.lowercased() == "https" else { throw InsecureURLError() }
        return try await upload(for: request, from: body, delegate: HTTPSRedirectsOnly.shared)
    }

    package func httpsDownload(for request: HTTPRequest) async throws -> (URL, HTTPResponse) {
        guard request.scheme?.lowercased() == "https" else { throw InsecureURLError() }
        return try await download(for: request, delegate: HTTPSRedirectsOnly.shared)
    }

    package func httpsDownload(from url: URL) async throws -> (URL, URLResponse) {
        guard url.isHTTPS else { throw InsecureURLError() }
        return try await download(from: url, delegate: HTTPSRedirectsOnly.shared)
    }
}

/// Checking the first URL alone would let an https address redirect to an
/// http one, which ATS no longer stops. Refused, the redirect's own reply is
/// what the caller gets, and no caller takes that for the file.
private final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = HTTPSRedirectsOnly()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.isHTTPS == true ? request : nil)
    }
}
