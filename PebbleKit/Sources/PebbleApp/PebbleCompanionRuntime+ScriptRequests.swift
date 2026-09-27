import PebbleProtocol
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import WebKit

extension PebbleCompanionRuntime {
    /// What the shim's `XMLHttpRequest` hands over.
    struct ScriptRequest {
        var id: Int
        var method: String
        var url: String
        var headers: [String: String]
        var body: String?
        var timeoutMilliseconds: Double
        /// `responseType = 'arraybuffer'`, which needs the bytes rather than
        /// their reading as text.
        var wantsBytes: Bool
    }

    /// Fetches on a script's behalf, which is what the shim's
    /// `XMLHttpRequest` hands over (#129). Only the web's own schemes: a
    /// script has no business reading file: or anything else the phone holds.
    func answerScriptRequest(_ script: ScriptRequest, page: WKWebView) async {
        var failure: String? = "error"
        defer {
            if let failure {
                Task { await deliverScriptResponse(requestID: script.id, page: page, failure: failure) }
            }
        }
        guard let applicationID = application?.id,
              let url = URL(string: script.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let method = HTTPRequest.Method(script.method.uppercased()) else { return }
        var fields = HTTPFields()
        for (name, value) in script.headers {
            guard let name = HTTPField.Name(name) else { continue }
            fields[name] = value
        }
        guard var request = URLRequest(httpRequest: HTTPRequest(method: method, url: url, headerFields: fields)) else {
            return
        }
        if script.timeoutMilliseconds > 0 { request.timeoutInterval = script.timeoutMilliseconds / 1000 }
        if let body = script.body { request.httpBody = Data(body.utf8) }
        let session = scriptSession(for: applicationID)
        do {
            guard let (data, http) = try await Self.fetchBody(
                request,
                session: session,
                limit: Self.scriptResponseLimit
            ) else { return }
            let headerText = http.allHeaderFields
                .compactMap { name, value -> String? in
                    guard let name = name as? String else { return nil }
                    return "\(name.lowercased()): \(value)"
                }
                .sorted()
                .joined(separator: "\r\n")
            failure = nil
            await deliverScriptResponse(
                requestID: script.id,
                page: page,
                status: http.statusCode,
                statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                responseText: Self.text(of: data, encodingName: http.textEncodingName),
                responseBase64: script.wantsBytes ? data.base64EncodedString() : "",
                responseHeaders: headerText
            )
        } catch {
            if (error as? URLError)?.code == .timedOut { failure = "timeout" }
            await DiagnosticLog.shared.record(
                category: "configuration",
                message: "a script's request could not be made: \(String(reflecting: error))"
            )
        }
    }

    /// Far beyond any API answer a watch app could hold, and a bound on what a
    /// hostile page could make the shim buffer.
    static let scriptResponseLimit = 10 * 1_024 * 1_024

    /// Nil when the answer is not HTTP or runs past `limit`. Counted as the
    /// bytes arrive rather than read whole with `data(for:)` and measured
    /// after: a body that gives no length is bounded by nothing until it has
    /// all been held.
    ///
    /// `@concurrent` so the millions of iterations a large body takes run off
    /// the main actor; a plain `nonisolated` function would run on its
    /// caller's, which is the main actor, under `NonisolatedNonsendingByDefault`.
    @concurrent
    static func fetchBody(
        _ request: URLRequest,
        session: URLSession,
        limit: Int
    ) async throws -> (Data, HTTPURLResponse)? {
        let (bytes, response) = try await session.bytes(for: request)
        let expected = response.expectedContentLength
        guard let http = response as? HTTPURLResponse, expected <= limit else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(min(expected, Int64(limit)))) }
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= limit else {
                bytes.task.cancel()
                return nil
            }
        }
        return (data, http)
    }

    func scriptSession(for applicationID: UUID) -> URLSession {
        if let session = scriptSessions[applicationID] { return session }
        let session = URLSession(configuration: .ephemeral)
        scriptSessions[applicationID] = session
        return session
    }

    /// The body as the response's own charset says, then as UTF-8, then as
    /// Latin-1, which reads any bytes at all.
    static func text(of data: Data, encodingName: String?) -> String {
        if let encodingName {
            let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(
                   data: data,
                   encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
               ) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// `failure` names the event the script is told of: `error`, or
    /// `timeout`.
    func deliverScriptResponse(
        requestID: Int,
        page: WKWebView,
        status: Int = 0,
        statusText: String = "",
        responseText: String = "",
        responseBase64: String = "",
        responseHeaders: String = "",
        failure: String? = nil
    ) async {
        guard let webView, webView === page else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__pebbleXHRResult(id, status, statusText, responseText, responseBase64, responseHeaders, failure);",
            arguments: [
                "id": requestID,
                "status": status,
                "statusText": statusText,
                "responseText": responseText,
                "responseBase64": responseBase64,
                "responseHeaders": responseHeaders,
                "failure": failure as Any,
            ],
            in: nil,
            contentWorld: .page
        )
    }
}
