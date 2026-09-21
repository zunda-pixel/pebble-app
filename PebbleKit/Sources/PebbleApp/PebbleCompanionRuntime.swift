import CoreLocation
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
    private var locationHandler: () async throws -> CLLocation
    /// A live stream of positions for `watchPosition`, or a throw where the
    /// phone has not been allowed to know. Throwing is the gate that keeps a
    /// script's request from ever raising the OS permission dialog itself.
    private var locationUpdatesHandler: @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error>
    /// A pin a script pushed, and the one it took back — owned by the
    /// application whose script said so.
    private var timelinePinInsertHandler: (CompanionTimelinePin, UUID) async -> Void
    private var timelinePinDeleteHandler: (String, UUID) async -> Void
    /// The launcher line a script reloaded, owned by the running application.
    /// Answers whether it was saved, which is what the script's callback says.
    private var appGlanceReloadHandler: ([AppGlanceSlice], UUID) async -> Bool
    /// One task per `watchPosition` call, keyed by the script's own watch id,
    /// cancelled by `clearWatch` and when the page goes away.
    private var positionWatchers: [Int: Task<Void, Never>] = [:]
    private var loadContinuation: CheckedContinuation<Void, any Error>?
    private var loadedApplicationID: UUID?
    /// The load under way (or the finished one, which costs nothing to await).
    /// A watch app sends a burst of messages on launch, and the second one used
    /// to find the identifier already claimed, skip the wait, and be delivered
    /// into a page whose script had not run — a NAK for nothing.
    private var loadTask: Task<Void, any Error>?
    /// True from a load's start until its continuation resumes, which is what
    /// `relaunch` reads to tell "the burst raced the run-state event" from
    /// "the same app launched again".
    private var isLoadInFlight = false
    private let tokenStore = PebbleTokenStore()

    init(
        openURLHandler: @escaping (URL) -> Void,
        appMessageHandler: @escaping (UUID, [AppMessageTuple]) async throws -> Void,
        notificationHandler: @escaping (WatchApplication, String, String) async throws -> Void,
        activeWatchHandler: @escaping () -> ConnectedWatch?,
        locationHandler: @escaping () async throws -> CLLocation,
        locationUpdatesHandler: @escaping @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error> = {
            throw WeatherSourceError.locationNotAllowed
        },
        timelinePinInsertHandler: @escaping (CompanionTimelinePin, UUID) async -> Void = { _, _ in },
        timelinePinDeleteHandler: @escaping (String, UUID) async -> Void = { _, _ in },
        appGlanceReloadHandler: @escaping ([AppGlanceSlice], UUID) async -> Bool = { _, _ in false }
    ) {
        self.openURLHandler = openURLHandler
        self.appMessageHandler = appMessageHandler
        self.notificationHandler = notificationHandler
        self.activeWatchHandler = activeWatchHandler
        self.locationHandler = locationHandler
        self.locationUpdatesHandler = locationUpdatesHandler
        self.timelinePinInsertHandler = timelinePinInsertHandler
        self.timelinePinDeleteHandler = timelinePinDeleteHandler
        self.appGlanceReloadHandler = appGlanceReloadHandler
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

    /// A fresh page for a fresh launch: the PKJS lifecycle ties the script to
    /// the watchapp's run, so launching the app runs `ready` again — a weather
    /// face refetches every time it is shown (#130). A load still in flight is
    /// joined instead, which is the launch's own appmessage burst racing the
    /// run-state event that called this.
    func relaunch(source: String, application: WatchApplication) async throws {
        if loadedApplicationID == application.id, isLoadInFlight {
            try await loadTask?.value
            return
        }
        loadedApplicationID = nil
        try await load(source: source, application: application)
    }

    func load(source: String, application: WatchApplication) async throws {
        if loadedApplicationID == application.id {
            // Claimed when the load starts, not when it finishes — so ride
            // whatever load claimed it rather than answering "loaded".
            try await loadTask?.value
            return
        }
        self.application = application
        let watch = activeWatchHandler()
        let sourceLiteral = try javaScriptLiteral(source)
        let identifierLiteral = try javaScriptLiteral(application.id.uuidString)
        let platformLiteral = try javaScriptLiteral(watch?.model?.platformName ?? "unknown")
        let modelLiteral = try javaScriptLiteral(watch?.model?.rawValue ?? "unknown")
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
          removeEventListener: (name, callback) => {
            listeners[name] = (listeners[name] || []).filter(fn => fn !== callback);
          },
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
          // Refused honestly rather than answered with a made-up token: the
          // real one is the Locker's, and this app has no account (#20, not
          // planned). Deferred so the caller's own frame finishes first, the
          // way the real answer would arrive.
          getTimelineToken: (onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineToken'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          insertTimelinePin: pin =>
            webkit.messageHandlers.pebble.postMessage({
              type:'insertPin', pin: typeof pin === 'string' ? pin : JSON.stringify(pin)
            }),
          deleteTimelinePin: pin =>
            webkit.messageHandlers.pebble.postMessage({
              type:'deletePin', id: String(typeof pin === 'object' && pin ? pin.id : pin)
            }),
          // The launcher line, reloaded by the running app's own script (#92).
          // The callbacks get the slices back, which is the SDK's shape.
          appGlanceReload: (slices, onSuccess, onFailure) => {
            const id = ++callbackID;
            callbacks[id] = {
              success: onSuccess ? (() => onSuccess(slices)) : undefined,
              failure: onFailure ? (() => onFailure(slices)) : undefined
            };
            webkit.messageHandlers.pebble.postMessage({
              type:'appGlance', id, slices: JSON.stringify(slices == null ? [] : slices)
            });
          },
          // Refused honestly, like getTimelineToken above: subscriptions need
          // a timeline service and an account, and this app has neither (#20,
          // not planned). Defined at all so a caller falls to its failure
          // branch instead of dying on undefined.
          timelineSubscribe: (topic, onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          timelineUnsubscribe: (topic, onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          timelineSubscriptions: (onSuccess, onFailure) => {
            webkit.messageHandlers.pebble.postMessage({type:'timelineSubscription'});
            setTimeout(() => onFailure && onFailure(), 0);
          },
          showSimpleNotificationOnPebble: (title, body) =>
            webkit.messageHandlers.pebble.postMessage({type:'notification', title, body})
        };
        // `navigator.geolocation` is here but never answers: WebKit has no
        // public way for an app to grant it, on `WKUIDelegate` or on the newer
        // `WebPage.DeviceSensorAuthorization`, whose permissions are
        // `deviceOrientationAndMotion` and `mediaCapture` and nothing else. So
        // it is replaced by one that asks the app, which has the position
        // already for the weather it sends the watch.
        const positions = {};
        let positionID = 0;
        const ask = (success, failure) => {
          const id = ++positionID;
          positions[id] = {success, failure};
          webkit.messageHandlers.pebble.postMessage({type:'position', id});
          return id;
        };
        Object.defineProperty(navigator, 'geolocation', {configurable: true, value: {
          getCurrentPosition: (success, failure) => { ask(success, failure); },
          // Followed, not answered once: the entry stays and the app keeps
          // delivering into it until clearWatch (#90).
          watchPosition: (success, failure) => {
            const id = ++positionID;
            positions[id] = {success, failure, watching: true};
            webkit.messageHandlers.pebble.postMessage({type:'watchPosition', id});
            return id;
          },
          clearWatch: id => {
            if (positions[id] && positions[id].watching)
              webkit.messageHandlers.pebble.postMessage({type:'clearWatch', id});
            delete positions[id];
          }
        }});
        window.__pebblePosition = (id, position, error) => {
          const cb = positions[id]; if (!cb) return;
          if (!cb.watching) delete positions[id];
          if (position) cb.success?.(position); else cb.failure?.(error);
        };
        // `XMLHttpRequest`, answered by the app rather than by WebKit: PKJS
        // scripts were written for a runtime without the web's same-origin
        // rules, and the services they call (wikipedia, hobbyist APIs) offer
        // no CORS headers to a pebble.local origin — through WebKit their
        // requests died silently (#129).
        const xhrs = {};
        let xhrID = 0;
        class PebbleXMLHttpRequest {
          constructor() {
            this.readyState = 0; this.status = 0; this.statusText = '';
            this.responseText = ''; this.response = ''; this.responseType = '';
            this.timeout = 0; this._headers = {}; this._responseHeaders = '';
          }
          open(method, url) { this._method = method; this._url = url; this.readyState = 1; }
          setRequestHeader(name, value) { this._headers[String(name)] = String(value); }
          getAllResponseHeaders() { return this._responseHeaders; }
          getResponseHeader(name) {
            const line = this._responseHeaders.split('\\r\\n')
              .find(l => l.toLowerCase().startsWith(String(name).toLowerCase() + ':'));
            return line ? line.slice(line.indexOf(':') + 1).trim() : null;
          }
          abort() { this._aborted = true; }
          send(body) {
            const id = ++xhrID; xhrs[id] = this;
            webkit.messageHandlers.pebble.postMessage({
              type: 'xhr', id, method: String(this._method || 'GET'), url: String(this._url),
              headers: this._headers, body: body == null ? null : String(body),
              timeout: Number(this.timeout) || 0
            });
          }
        }
        window.__pebbleXHRResult = (id, status, statusText, responseText, responseHeaders, failed) => {
          const x = xhrs[id]; if (!x) return;
          delete xhrs[id];
          if (x._aborted) return;
          x.readyState = 4;
          if (failed) {
            if (x.onreadystatechange) x.onreadystatechange();
            if (x.onerror) x.onerror();
            if (x.onloadend) x.onloadend();
            return;
          }
          x.status = status; x.statusText = statusText;
          x.responseText = responseText; x._responseHeaders = responseHeaders;
          if (x.responseType === 'json') {
            try { x.response = JSON.parse(responseText); } catch (e) { x.response = null; }
          } else {
            x.response = responseText;
          }
          if (x.onreadystatechange) x.onreadystatechange();
          if (x.onload) x.onload();
          if (x.onloadend) x.onloadend();
        };
        window.XMLHttpRequest = PebbleXMLHttpRequest;
        window.__pebbleDispatch = (name, detail) => (listeners[name] || []).forEach(fn => fn(detail));
        window.__pebbleResult = (id, ok) => { const cb = callbacks[id]; if (!cb) return;
          delete callbacks[id]; (ok ? cb.success : cb.failure)?.(); };
        window.__pebbleApplicationID = \(identifierLiteral);
        eval(\(sourceLiteral));
        window.__pebbleDispatch('ready', {});
        </script>
        """
        // The page being replaced takes its watchers with it: their
        // callbacks live in the page.
        cancelPositionWatchers()
        let webView = makeWebView(for: application)
        self.webView = webView
        loadedApplicationID = application.id
        isLoadInFlight = true
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                loadContinuation?.resume(throwing: CancellationError())
                loadContinuation = continuation
                // A real origin rather than `about:blank`, which is what gives the
                // script `localStorage` at all and lets it fetch across origins.
                webView.loadHTMLString(
                    html,
                    baseURL: URL(string: "https://\(application.id.uuidString.lowercased()).pebble.local/")
                )
            }
        }
        loadTask = task
        defer { isLoadInFlight = false }
        try await task.value
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
        // Under both spellings: the name the appKeys declare, which is how the
        // SDK's own samples read a payload, and the number, which is how the
        // older ones do. Numbers alone left every name-reading script deaf to
        // the watch (#128) — WikiRadius waited forever for a READY it had
        // already been sent.
        let names = Dictionary(
            (application?.appKeys ?? [:]).map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        var payload: [String: Any] = [:]
        for tuple in message.tuples {
            let value = javaScriptValue(tuple.value)
            payload[String(tuple.key)] = value
            if let name = names[tuple.key] {
                payload[name] = value
            }
        }
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
        if type == "position", let requestID = body["id"] as? Int {
            Task { await answerPosition(requestID: requestID) }
            return
        }
        if type == "watchPosition", let requestID = body["id"] as? Int {
            startPositionWatcher(requestID: requestID)
            return
        }
        if type == "clearWatch", let requestID = body["id"] as? Int {
            positionWatchers.removeValue(forKey: requestID)?.cancel()
            return
        }
        if type == "xhr", let requestID = body["id"] as? Int {
            let method = body["method"] as? String ?? "GET"
            let urlString = body["url"] as? String ?? ""
            let headers = body["headers"] as? [String: String] ?? [:]
            let requestBody = body["body"] as? String
            let timeout = body["timeout"] as? Double ?? 0
            Task {
                await answerScriptRequest(
                    requestID: requestID,
                    method: method,
                    urlString: urlString,
                    headers: headers,
                    body: requestBody,
                    timeoutMilliseconds: timeout
                )
            }
            return
        }
        if type == "appGlance",
           let requestID = body["id"] as? Int,
           let slicesJSON = body["slices"] as? String,
           let application {
            let applicationID = application.id
            Task {
                do {
                    let slices = try CompanionAppGlance.slices(from: slicesJSON)
                    let saved = await appGlanceReloadHandler(slices, applicationID)
                    try? await resolve(callbackID: requestID, succeeded: saved)
                } catch {
                    try? await resolve(callbackID: requestID, succeeded: false)
                    await DiagnosticLog.shared.record(
                        .warning,
                        category: "timeline",
                        message: "an application's glance was refused: \(String(reflecting: error))"
                    )
                }
            }
            return
        }
        if type == "timelineSubscription" {
            Task {
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "an application asked about timeline subscriptions;"
                        + " there is no timeline service to subscribe through (#20)"
                )
            }
            return
        }
        if type == "timelineToken" {
            Task {
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "an application asked for a timeline token;"
                        + " this app has no account to mint one (#20)"
                )
            }
            return
        }
        if type == "insertPin", let pinJSON = body["pin"] as? String, let application {
            let applicationID = application.id
            Task {
                do {
                    let pin = try CompanionTimelinePin.parse(pinJSON)
                    await timelinePinInsertHandler(pin, applicationID)
                } catch {
                    // The official API takes no callback here, so a broken pin
                    // can only be told to the diagnostics.
                    await DiagnosticLog.shared.record(
                        .warning,
                        category: "timeline",
                        message: "an application's pin was refused: \(String(reflecting: error))"
                    )
                }
            }
            return
        }
        if type == "deletePin", let backingID = body["id"] as? String, let application {
            let applicationID = application.id
            Task { await timelinePinDeleteHandler(backingID, applicationID) }
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

    /// The third way a load ends: WebKit's content process dying delivers
    /// neither `didFinish` nor `didFail…`, and a continuation resumed by
    /// nobody would park every later message behind it for the life of the
    /// app. The next message starts a fresh page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadedApplicationID = nil
        cancelPositionWatchers()
        loadContinuation?.resume(throwing: CompanionRuntimeError.pageWentAway)
        loadContinuation = nil
    }

    /// Follows the phone's position for a script's `watchPosition`, delivering
    /// every fix into the same callback until `clearWatch` or the page's end.
    private func startPositionWatcher(requestID: Int) {
        positionWatchers.removeValue(forKey: requestID)?.cancel()
        positionWatchers[requestID] = Task { [weak self] in
            do {
                guard let updates = try self?.locationUpdatesHandler() else { return }
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "a script is watching the position (watch \(requestID))"
                )
                // The first fix, straight away: the live stream can take
                // seconds to warm up, and the single-shot path already holds a
                // recent one. A script's first paint should not wait on GPS.
                if let seed = try? await self?.locationHandler() {
                    guard !Task.isCancelled else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        position: Self.webPosition(seed),
                        error: nil
                    )
                }
                var delivered = 0
                for try await location in updates {
                    guard !Task.isCancelled else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        position: Self.webPosition(location),
                        error: nil
                    )
                    delivered += 1
                    if delivered == 1 {
                        await DiagnosticLog.shared.record(
                            category: "configuration",
                            message: "the watched position delivered its first live fix (watch \(requestID))"
                        )
                    }
                }
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "the position stream ended (watch \(requestID), \(delivered) live fixes)"
                )
            } catch {
                guard !Task.isCancelled else { return }
                let refused = (error as? WeatherSourceError) == .locationNotAllowed
                await self?.deliverPosition(
                    requestID: requestID,
                    position: nil,
                    error: [
                        "code": refused ? 1 : 2,
                        "message": refused
                            ? "Pebble has not been allowed your position."
                            : "Your position could not be found.",
                    ]
                )
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "a watched position failed (watch \(requestID)): \(String(reflecting: error))"
                )
            }
        }
    }

    /// Fetches on a script's behalf, which is what the shim's
    /// `XMLHttpRequest` hands over (#129). Only the web's own schemes: a
    /// script has no business reading file: or anything else the phone holds.
    private func answerScriptRequest(
        requestID: Int,
        method: String,
        urlString: String,
        headers: [String: String],
        body: String?,
        timeoutMilliseconds: Double
    ) async {
        var answered = false
        defer {
            if !answered {
                Task { await deliverScriptResponse(requestID: requestID, failed: true) }
            }
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if timeoutMilliseconds > 0 { request.timeoutInterval = timeoutMilliseconds / 1000 }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body { request.httpBody = Data(body.utf8) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            // Far beyond any API answer a watch app could hold, and a bound on
            // what a hostile page could make the shim buffer.
            guard data.count <= 10 * 1_024 * 1_024,
                  let http = response as? HTTPURLResponse else { return }
            let headerText = http.allHeaderFields
                .compactMap { name, value -> String? in
                    guard let name = name as? String else { return nil }
                    return "\(name.lowercased()): \(value)"
                }
                .sorted()
                .joined(separator: "\r\n")
            answered = true
            await deliverScriptResponse(
                requestID: requestID,
                status: http.statusCode,
                statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                responseText: String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) ?? "",
                responseHeaders: headerText
            )
        } catch {
            await DiagnosticLog.shared.record(
                category: "configuration",
                message: "a script's request could not be made: \(String(reflecting: error))"
            )
        }
    }

    private func deliverScriptResponse(
        requestID: Int,
        status: Int = 0,
        statusText: String = "",
        responseText: String = "",
        responseHeaders: String = "",
        failed: Bool = false
    ) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__pebbleXHRResult(id, status, statusText, responseText, responseHeaders, failed);",
            arguments: [
                "id": requestID,
                "status": status,
                "statusText": statusText,
                "responseText": responseText,
                "responseHeaders": responseHeaders,
                "failed": failed,
            ],
            in: nil,
            contentWorld: .page
        )
    }

    /// The page is going or gone: nobody is left to deliver positions to.
    private func cancelPositionWatchers() {
        for watcher in positionWatchers.values { watcher.cancel() }
        positionWatchers = [:]
    }

    /// Answers a script's request for a position, in the shape the web has for
    /// one so that a script written against a browser reads it unchanged.
    private func answerPosition(requestID: Int) async {
        do {
            let location = try await locationHandler()
            await deliverPosition(requestID: requestID, position: Self.webPosition(location), error: nil)
        } catch {
            // The codes are the web's: 1 refused, 2 could not be found, 3 took
            // too long. Refused is the one worth telling apart — the reader can
            // do something about it, and the others they cannot.
            let refused = (error as? WeatherSourceError) == .locationNotAllowed
            await deliverPosition(
                requestID: requestID,
                position: nil,
                error: [
                    "code": refused ? 1 : 2,
                    "message": refused
                        ? "Pebble has not been allowed your position."
                        : "Your position could not be found.",
                ]
            )
            await DiagnosticLog.shared.record(
                .warning,
                category: "configuration",
                message: "an application asked for a position and did not get one:"
                    + " \(String(reflecting: error))"
            )
        }
    }

    private func deliverPosition(
        requestID: Int,
        position: [String: Any]?,
        error: [String: Any]?
    ) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            "window.__pebblePosition(id, position, error);",
            arguments: [
                "id": requestID,
                "position": position as Any,
                "error": error as Any,
            ],
            in: nil,
            contentWorld: .page
        )
    }

    /// A `CLLocation` as a `GeolocationPosition`.
    ///
    /// CoreLocation says "I do not know" with a negative number, and the web
    /// says it with null; passing the negative through would have a script
    /// draw a heading of -1 degrees.
    private static func webPosition(_ location: CLLocation) -> [String: Any] {
        func known(_ value: CLLocationDistance) -> Any {
            value < 0 ? NSNull() : value
        }
        return [
            "coords": [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "accuracy": known(location.horizontalAccuracy),
                "altitude": location.verticalAccuracy < 0 ? NSNull() as Any : location.altitude as Any,
                "altitudeAccuracy": known(location.verticalAccuracy),
                "heading": known(location.course),
                "speed": known(location.speed),
            ],
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
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
    /// WebKit's content process went away mid-load.
    case pageWentAway
}
