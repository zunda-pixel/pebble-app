import Foundation
import Synchronization

/// A stubbed store, so the catalogue can be asked without one.
///
/// Answers 404 for anything not registered, which is what the real store does
/// for a UUID it has never listed.
final class StoreStubURLProtocol: URLProtocol {
    private static let answers = Mutex<[URL: Data]>([:])

    static func answer(_ url: URL, with data: Data) {
        answers.withLock { $0[url] = data }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let body = Self.answers.withLock { $0[url] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let body {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
