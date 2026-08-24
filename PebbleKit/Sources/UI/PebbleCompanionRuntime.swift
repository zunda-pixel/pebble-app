import API
import Foundation
import WebKit

@MainActor
final class PebbleCompanionRuntime: NSObject, @preconcurrency WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView
    private var application: PebbleApplication?
    private var openURLHandler: (URL) -> Void
    private var appMessageHandler: (UUID, [AppMessageTuple]) async throws -> Void
    private var notificationHandler: (PebbleApplication, String, String) async throws -> Void
    private var loadContinuation: CheckedContinuation<Void, any Error>?

    init(
        openURLHandler: @escaping (URL) -> Void,
        appMessageHandler: @escaping (UUID, [AppMessageTuple]) async throws -> Void,
        notificationHandler: @escaping (PebbleApplication, String, String) async throws -> Void
    ) {
        self.openURLHandler = openURLHandler
        self.appMessageHandler = appMessageHandler
        self.notificationHandler = notificationHandler
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "pebble")
        webView.navigationDelegate = self
    }

    func load(source: String, application: PebbleApplication) async throws {
        self.application = application
        let sourceLiteral = try javaScriptLiteral(source)
        let identifierLiteral = try javaScriptLiteral(application.id.uuidString)
        let html = """
        <!doctype html><meta charset="utf-8"><script>
        const listeners = {};
        const callbacks = {};
        let callbackID = 0;
        window.Pebble = {
          addEventListener: (name, callback) => (listeners[name] ||= []).push(callback),
          openURL: url => webkit.messageHandlers.pebble.postMessage({type:'openURL', url}),
          sendAppMessage: (message, success, failure) => {
            const id = ++callbackID; callbacks[id] = {success, failure};
            webkit.messageHandlers.pebble.postMessage({type:'sendAppMessage', id, message});
          },
          getActiveWatchInfo: () => ({platform:'unknown', model:'unknown', language:'en'}),
          getAccountToken: () => '', getWatchToken: () => '',
          showSimpleNotificationOnPebble: (title, body) =>
            webkit.messageHandlers.pebble.postMessage({type:'notification', title, body})
        };
        window.__pebbleDispatch = (name, detail) => (listeners[name] || []).forEach(fn => fn(detail));
        window.__pebbleResult = (id, ok) => { const cb = callbacks[id]; if (!cb) return;
          delete callbacks[id]; (ok ? cb.success : cb.failure)?.(); };
        window.__pebbleApplicationID = \(identifierLiteral);
        eval(\(sourceLiteral));
        window.__pebbleDispatch('ready', {});
        </script>
        """
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation?.resume(throwing: CancellationError())
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func showConfiguration() async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleDispatch('showConfiguration', {});",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    func closeConfiguration(response: String?) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleDispatch('webviewclosed', {response: response});",
            arguments: ["response": response as Any],
            in: nil,
            contentWorld: .page
        )
    }

    func deliver(_ message: AppMessageData) async throws {
        let payload = Dictionary(uniqueKeysWithValues: message.tuples.map { tuple in
            (String(tuple.key), javaScriptValue(tuple.value))
        })
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleDispatch('appmessage', {payload: payload});",
            arguments: ["payload": payload],
            in: nil,
            contentWorld: .page
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "openURL", let value = body["url"] as? String, let url = URL(string: value) {
            openURLHandler(url)
            return
        }
        if type == "notification",
           let title = body["title"] as? String,
           let notificationBody = body["body"] as? String,
           let application {
            Task { try? await notificationHandler(application, title, notificationBody) }
            return
        }
        guard type == "sendAppMessage",
              let callbackID = body["id"] as? Int,
              let values = body["message"] as? [String: Any],
              let application else { return }
        let tuples = values.compactMap { key, value -> AppMessageTuple? in
            let numericKey = application.appKeys[key] ?? UInt32(key)
            guard let numericKey, let appValue = appMessageValue(value) else { return nil }
            return AppMessageTuple(key: numericKey, value: appValue)
        }
        Task {
            do {
                try await appMessageHandler(application.id, tuples)
                try await resolve(callbackID: callbackID, succeeded: true)
            } catch {
                try? await resolve(callbackID: callbackID, succeeded: false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    private func resolve(callbackID: Int, succeeded: Bool) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleResult(id, ok);",
            arguments: ["id": callbackID, "ok": succeeded],
            in: nil,
            contentWorld: .page
        )
    }

    private func appMessageValue(_ value: Any) -> AppMessageValue? {
        switch value {
        case let value as String: .string(value)
        case let value as NSNumber:
            value.int64Value < 0 ? .signed(value.int32Value) : .unsigned(value.uint32Value)
        case let value as [UInt8]: .bytes(value)
        default: nil
        }
    }

    private func javaScriptValue(_ value: AppMessageValue) -> Any {
        switch value {
        case .bytes(let bytes): bytes
        case .string(let string): string
        case .unsigned(let number): number
        case .signed(let number): number
        }
    }

    private func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return literal
    }
}
