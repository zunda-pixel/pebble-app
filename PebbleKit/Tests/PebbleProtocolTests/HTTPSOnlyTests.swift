import Foundation
import HTTPTypes
import Testing
@testable import PebbleProtocol

@Suite
struct HTTPSOnlyTests {
    @Test func aPlainHTTPRequestIsRefusedBeforeItIsSent() async {
        let url = URL(string: "http://example.invalid/https-only/feed.json")!
        StubURLProtocol.stub(url, status: 200, body: Data("[]".utf8))

        await #expect(throws: InsecureURLError()) {
            try await StubURLProtocol.session().httpsData(for: HTTPRequest(method: .get, url: url))
        }
        #expect(StubURLProtocol.requestCount(for: url) == 0)
    }

    @Test func aPlainHTTPUploadIsRefusedBeforeItIsSent() async {
        let url = URL(string: "http://example.invalid/https-only/search")!
        StubURLProtocol.stub(url, status: 200)

        await #expect(throws: InsecureURLError()) {
            try await StubURLProtocol.session().httpsUpload(for: HTTPRequest(method: .post, url: url), from: Data())
        }
        #expect(StubURLProtocol.requestCount(for: url) == 0)
    }

    @Test func anHTTPSRequestIsSent() async throws {
        let url = URL(string: "https://example.invalid/https-only/feed.json")!
        StubURLProtocol.stub(url, status: 200, body: Data("[]".utf8))

        let (data, response) = try await StubURLProtocol.session().httpsData(for: HTTPRequest(method: .get, url: url))

        #expect(response.status == .ok)
        #expect(data == Data("[]".utf8))
    }

    @Test func aCatalogueAtAPlainHTTPAddressIsRefusedWithoutARetry() async {
        let url = URL(string: "http://example.invalid/https-only/releases")!
        StubURLProtocol.stub(url, status: 200, body: Data("[]".utf8))
        let catalog = PebbleOSFirmwareCatalog(releasesURL: url, session: StubURLProtocol.session())

        await #expect(throws: InsecureURLError()) {
            try await catalog.latestRelease(for: .obelixPVT)
        }
        #expect(StubURLProtocol.requestCount(for: url) == 0)
    }
}
