import PebbleProtocol
import Foundation
import WebKit

@MainActor
final class PebbleCompanionRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Made per application, because the store it keeps its settings in is
    /// named after the application and a `WKWebView` takes its store when it is
    /// built.
    private var webView: WKWebView?
    private var application: WatchApplication?
    private var openURLHandler: (URL) -> Void
    private var appMessageHandler: (UUID, [AppMessageTuple]) async throws -> Void
    private var notificationHandler: (WatchApplication, String, String) async throws -> Void
    private var activeWatchHandler: () -> ConnectedWatch?
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var loadedApplicationID: UUID?
    private let tokenStore = PebbleTokenStore()

    init(
        openURLHandler: @escaping (URL) -> Void,
        appMessageHandler: @escaping (UUID, [AppMessageTuple]) async throws -> Void,
        notificationHandler: @escaping (WatchApplication, String, String) async throws -> Void,
        activeWatchHandler: @escaping () -> ConnectedWatch?
    ) {
        self.openURLHandler = openURLHandler
        self.appMessageHandler = appMessageHandler
        self.notificationHandler = notificationHandler
        self.activeWatchHandler = activeWatchHandler
        super.init()
    }

    /// A web view whose storage is the application's own and survives a launch.
    ///
    /// The store used to be `.nonPersistent()`, which is memory and goes with
    /// the process: a watch app that keeps its settings in `localStorage` — the
    /// usual place for them — was set up again on every launch. Named after the
    /// application, so one app's settings are not another's, and so removing
    /// the app can take its settings with it.
    private func makeWebView(for application: WatchApplication) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: application.id)
        configuration.userContentController.add(self, name: "pebble")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    /// Lets go of what an application kept, for when the reader lets go of the
    /// application. Left behind, it would come back as the old settings of a
    /// watch app installed again under the same identifier.
    static func forget(applicationID: UUID) async {
        try? await WKWebsiteDataStore.remove(forIdentifier: applicationID)
    }

    func load(source: String, application: WatchApplication) async throws {
        if loadedApplicationID == application.id { return }
        self.application = application
        let watch = activeWatchHandler()
        let sourceLiteral = try javaScriptLiteral(source)
        let identifierLiteral = try javaScriptLiteral(application.id.uuidString)
        let platformLiteral = try javaScriptLiteral(watch?.model.platformName ?? "unknown")
        let modelLiteral = try javaScriptLiteral(watch?.model.rawValue ?? "unknown")
        let firmwareLiteral = try javaScriptLiteral(watch?.firmwareVersion ?? "unknown")
        let accountTokenLiteral = try javaScriptLiteral(
            tokenStore.token(named: PebbleTokenStore.accountTokenName)
        )
        let watchTokenLiteral = try javaScriptLiteral(
            tokenStore.token(named: PebbleTokenStore.watchTokenName(watchID: watch?.id ?? WatchID("unknown")))
        )
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
          getActiveWatchInfo: () => ({
            platform: \(platformLiteral), model: \(modelLiteral), language: navigator.language,
            firmware: {major: 0, minor: 0, patch: 0, suffix: \(firmwareLiteral)}
          }),
          getAccountToken: () => \(accountTokenLiteral),
          getWatchToken: () => \(watchTokenLiteral),
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
        let webView = makeWebView(for: application)
        self.webView = webView
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation?.resume(throwing: CancellationError())
            loadContinuation = continuation
        loadedApplicationID = application.id
        // A real origin rather than `about:blank`, which is what gives the
        // script `localStorage` at all and lets it fetch across origins.
        webView.loadHTMLString(
            html,
            baseURL: URL(string: "https://\(application.id.uuidString.lowercased()).pebble.local/")
        )
        }
    }

    func showConfiguration() async throws {
        guard let webView else { throw CompanionRuntimeError.noApplicationLoaded }
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleDispatch('showConfiguration', {});",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
    }

    func closeConfiguration(response: String?) async throws {
        guard let webView else { throw CompanionRuntimeError.noApplicationLoaded }
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
        guard let webView else { throw CompanionRuntimeError.noApplicationLoaded }
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
        loadedApplicationID = nil
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        loadedApplicationID = nil
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    private func resolve(callbackID: Int, succeeded: Bool) async throws {
        guard let webView else { throw CompanionRuntimeError.noApplicationLoaded }
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

private extension WatchModel {
    var platformName: String {
        switch self {
        case .pebble2Duo: "flint"
        case .pebbleTime2: "emery"
        case .pebbleRound2: "gabbro"
        }
    }
}

/// Asked of a runtime with no script in it.
///
/// Thrown rather than shrugged off: the callers reach these only after
/// `load(source:application:)`, so a nil web view means the load was never
/// made or has been replaced, and an empty answer would read as the script
/// having nothing to say.
enum CompanionRuntimeError: Error {
    case noApplicationLoaded
}
