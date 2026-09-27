import CoreLocation
import PebbleProtocol
import Foundation
import HTTPTypes
import HTTPTypesFoundation
import WebKit

@MainActor
final class PebbleCompanionRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Made per application, because the store it keeps its settings in is
    /// named after the application and a `WKWebView` takes its store when it is
    /// built.
    private var webView: WKWebView?
    private var application: WatchApplication?
    private let openURLHandler: (URL) -> Void
    private let appMessageHandler: (UUID, [AppMessageTuple]) async throws -> Void
    private let notificationHandler: (WatchApplication, String, String) async -> Void
    private let activeWatchHandler: () -> ConnectedWatch?
    private let locationHandler: () async throws -> CLLocation
    /// A live stream of positions for `watchPosition`, or a throw where the
    /// phone has not been allowed to know. Throwing is the gate that keeps a
    /// script's request from ever raising the OS permission dialog itself.
    private let locationUpdatesHandler: @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error>
    /// A pin a script pushed, and the one it took back — owned by the
    /// application whose script said so.
    private let timelinePinInsertHandler: (CompanionTimelinePin, UUID) async -> Void
    private let timelinePinDeleteHandler: (String, UUID) async -> Void
    /// The launcher line a script reloaded, owned by the running application.
    /// Answers whether it was saved, which is what the script's callback says.
    private let appGlanceReloadHandler: ([AppGlanceSlice], UUID) async -> Bool
    /// One task per `watchPosition` call, keyed by the script's own watch id,
    /// cancelled by `clearWatch` and when the page goes away.
    private var positionWatchers: [Int: Task<Void, Never>] = [:]
    /// Each application's own session for its script's requests, as the web
    /// view's store is. Sharing `URLSession.shared` sent a cookie one app was
    /// handed along with every other app's requests. Ephemeral: a script's
    /// cookies were never meant to outlive the process any more than a page's.
    private var scriptSessions: [UUID: URLSession] = [:]
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
    /// Which load `isLoadInFlight` speaks for. A load superseded by the next
    /// one returns while the next is still under way, and lowering the flag
    /// then would have `relaunch` build a third page instead of joining it.
    private var loadGeneration = 0
    private let tokenStore = PebbleTokenStore()

    init(
        openURLHandler: @escaping (URL) -> Void,
        appMessageHandler: @escaping (UUID, [AppMessageTuple]) async throws -> Void,
        notificationHandler: @escaping (WatchApplication, String, String) async -> Void,
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
        // Removing a store before anything else in the process has touched
        // WebKit crashes inside it: `removeDataStoreWithIdentifierImpl`
        // finishes on the main RunLoop, which WebKit has not set up yet
        // (SIGSEGV on the WebsiteDataStoreIO queue, iOS 27.2). A reader who
        // removes an app without having opened a settings page or run its
        // JavaScript in this launch is exactly that case. The default store is
        // touched rather than this app's own, which would put it in use.
        _ = WKWebsiteDataStore.default()
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
        let watchInfo = try Self.watchInfoLiteral(for: watch, running: application)
        let accountTokenLiteral = try javaScriptLiteral(
            tokenStore.accountToken(applicationID: application.id)
        )
        let watchTokenLiteral = try javaScriptLiteral(
            tokenStore.watchToken(applicationID: application.id, watch: watch)
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
          // WebKit hands a boolean over as a number that Swift cannot tell
          // from 1, so it is made one here.
          sendAppMessage: (message, success, failure) => {
            const id = ++callbackID; callbacks[id] = {success, failure};
            const values = {};
            for (const [key, value] of Object.entries(message || {}))
              values[key] = typeof value === 'boolean' ? (value ? 1 : 0) : value;
            webkit.messageHandlers.pebble.postMessage({type:'sendAppMessage', id, message: values});
            return id;
          },
          getActiveWatchInfo: () => (\(watchInfo)),
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
          // As text whatever was passed: a number or a missing body used to
          // fail the cast on the phone's side and the notification with it.
          showSimpleNotificationOnPebble: (title, body) =>
            webkit.messageHandlers.pebble.postMessage({
              type:'notification', title: String(title ?? ''), body: String(body ?? '')
            })
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
            this._listeners = {};
          }
          addEventListener(type, callback) { (this._listeners[type] ||= []).push(callback); }
          removeEventListener(type, callback) {
            this._listeners[type] = (this._listeners[type] || []).filter(fn => fn !== callback);
          }
          _fire(type) {
            const event = {type, target: this, currentTarget: this};
            if (typeof this['on' + type] === 'function') this['on' + type](event);
            (this._listeners[type] || []).slice().forEach(fn => fn.call(this, event));
          }
          open(method, url, async) {
            this._method = method; this._url = url; this._synchronous = async === false;
            this._aborted = false; this.readyState = 1; this._fire('readystatechange');
          }
          setRequestHeader(name, value) { this._headers[String(name)] = String(value); }
          getAllResponseHeaders() { return this._responseHeaders; }
          getResponseHeader(name) {
            const line = this._responseHeaders.split('\\r\\n')
              .find(l => l.toLowerCase().startsWith(String(name).toLowerCase() + ':'));
            return line ? line.slice(line.indexOf(':') + 1).trim() : null;
          }
          abort() {
            if (this._aborted || this.readyState === 0 || this.readyState === 4) return;
            this._aborted = true;
            this.readyState = 4; this.status = 0;
            this._fire('readystatechange'); this._fire('abort'); this._fire('loadend');
            this.readyState = 0;
          }
          // Refused rather than answered empty: the answer comes back through
          // a message, so a script reading responseText right after send()
          // would carry on with nothing and never learn why.
          send(body) {
            if (this._synchronous) {
              webkit.messageHandlers.pebble.postMessage({type: 'synchronousXHR', url: String(this._url)});
              throw new DOMException('Synchronous requests are not supported', 'InvalidAccessError');
            }
            const id = ++xhrID; xhrs[id] = this;
            webkit.messageHandlers.pebble.postMessage({
              type: 'xhr', id, method: String(this._method || 'GET'), url: String(this._url),
              headers: this._headers, body: body == null ? null : String(body),
              timeout: Number(this.timeout) || 0, responseType: String(this.responseType || '')
            });
          }
        }
        window.__pebbleXHRResult = (id, status, statusText, responseText, responseBase64, responseHeaders, failure) => {
          const x = xhrs[id]; if (!x) return;
          delete xhrs[id];
          if (x._aborted) return;
          x.readyState = 4;
          if (failure) {
            x._fire('readystatechange'); x._fire(failure); x._fire('loadend');
            return;
          }
          x.status = status; x.statusText = statusText;
          x.responseText = responseText; x._responseHeaders = responseHeaders;
          if (x.responseType === 'json') {
            try { x.response = JSON.parse(responseText); } catch (e) { x.response = null; }
          } else if (x.responseType === 'arraybuffer') {
            x.response = Uint8Array.from(atob(responseBase64 || ''), c => c.charCodeAt(0)).buffer;
          } else {
            x.response = responseText;
          }
          x._fire('readystatechange'); x._fire('load'); x._fire('loadend');
        };
        window.XMLHttpRequest = PebbleXMLHttpRequest;
        window.__pebbleDispatch = (name, detail) => (listeners[name] || []).forEach(fn => fn(detail));
        // The official runtime's shapes: `{data: {transactionId}}`, and on a
        // refusal the same with `error: "nack"`, passed again as the second
        // argument.
        window.__pebbleResult = (id, ok) => { const cb = callbacks[id]; if (!cb) return;
          delete callbacks[id];
          const e = ok ? {data: {transactionId: id}} : {data: {transactionId: id}, error: 'nack'};
          (ok ? cb.success : cb.failure)?.(e, e.error); };
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
        loadGeneration += 1
        let generation = loadGeneration
        isLoadInFlight = true
        let task = Task {
            try await withCheckedThrowingContinuation { continuation in
                loadContinuation?.resume(throwing: CancellationError())
                loadContinuation = continuation
                // A real origin rather than `about:blank`, which is what gives the
                // script `localStorage` at all and lets it fetch across origins.
                webView.loadHTMLString(
                    html,
                    baseURL: URL(string: "https://\(Self.originHost(of: application.id))/")
                )
            }
        }
        loadTask = task
        defer {
            if loadGeneration == generation { isLoadInFlight = false }
        }
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
        guard let page = message.webView, page === webView,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let application else { return }
        // A script that navigates its page elsewhere, or loads a frame, hands
        // this handler to whatever it loaded — which would then send app
        // messages, read the position and fetch through the app.
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              origin.protocol == "https",
              origin.host == Self.originHost(of: application.id) else {
            Task {
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "a message from outside \(application.shortName)'s own page was ignored"
                )
            }
            return
        }
        if type == "openURL", let value = body["url"] as? String, let url = URL(string: value) {
            openURLHandler(url)
            return
        }
        if type == "position", let requestID = body["id"] as? Int {
            Task { await answerPosition(requestID: requestID, page: page) }
            return
        }
        if type == "watchPosition", let requestID = body["id"] as? Int {
            startPositionWatcher(requestID: requestID, page: page)
            return
        }
        if type == "clearWatch", let requestID = body["id"] as? Int {
            positionWatchers.removeValue(forKey: requestID)?.cancel()
            return
        }
        if type == "xhr", let requestID = body["id"] as? Int {
            let request = ScriptRequest(
                id: requestID,
                method: body["method"] as? String ?? "GET",
                url: body["url"] as? String ?? "",
                headers: body["headers"] as? [String: String] ?? [:],
                body: body["body"] as? String,
                timeoutMilliseconds: body["timeout"] as? Double ?? 0,
                wantsBytes: body["responseType"] as? String == "arraybuffer"
            )
            Task { await answerScriptRequest(request, page: page) }
            return
        }
        if type == "synchronousXHR" {
            let url = body["url"] as? String ?? ""
            Task {
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "\(application.shortName) made a synchronous request, which is refused: \(url)"
                )
            }
            return
        }
        if type == "appGlance",
           let requestID = body["id"] as? Int,
           let slicesJSON = body["slices"] as? String {
            let applicationID = application.id
            Task {
                do {
                    let slices = try CompanionAppGlance.slices(from: slicesJSON)
                    let saved = await appGlanceReloadHandler(slices, applicationID)
                    try? await resolve(callbackID: requestID, succeeded: saved, page: page)
                } catch {
                    try? await resolve(callbackID: requestID, succeeded: false, page: page)
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
        if type == "insertPin", let pinJSON = body["pin"] as? String {
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
        if type == "deletePin", let backingID = body["id"] as? String {
            let applicationID = application.id
            Task { await timelinePinDeleteHandler(backingID, applicationID) }
            return
        }
        if type == "notification",
           let title = body["title"] as? String,
           let notificationBody = body["body"] as? String {
            Task { await notificationHandler(application, title, notificationBody) }
            return
        }
        guard type == "sendAppMessage",
              let callbackID = body["id"] as? Int,
              let values = body["message"] as? [String: Any] else { return }
        var tuples: [AppMessageTuple] = []
        var dropped: [String] = []
        for (key, value) in values {
            guard let numericKey = application.appKeys[key] ?? UInt32(key),
                  let appValue = Self.appMessageValue(value) else {
                dropped.append(key)
                continue
            }
            tuples.append(AppMessageTuple(key: numericKey, value: appValue))
        }
        if !dropped.isEmpty {
            Task {
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "\(application.shortName) sent keys the watch cannot be given:"
                        + " \(dropped.sorted().joined(separator: ", "))"
                )
            }
        }
        Task {
            do {
                try await appMessageHandler(application.id, tuples)
                try await resolve(callbackID: callbackID, succeeded: true, page: page)
            } catch {
                try? await resolve(callbackID: callbackID, succeeded: false, page: page)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        guard webView === self.webView else { return }
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        loadedApplicationID = nil
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: any Error
    ) {
        guard webView === self.webView else { return }
        loadedApplicationID = nil
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    /// The third way a load ends: WebKit's content process dying delivers
    /// neither `didFinish` nor `didFail…`, and a continuation resumed by
    /// nobody would park every later message behind it for the life of the
    /// app. The next message starts a fresh page.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        loadedApplicationID = nil
        cancelPositionWatchers()
        loadContinuation?.resume(throwing: CompanionRuntimeError.pageWentAway)
        loadContinuation = nil
    }

    /// Follows the phone's position for a script's `watchPosition`, delivering
    /// every fix into the same callback until `clearWatch` or the page's end.
    private func startPositionWatcher(requestID: Int, page: WKWebView) {
        positionWatchers.removeValue(forKey: requestID)?.cancel()
        positionWatchers[requestID] = Task { [weak self, weak page] in
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
                    guard !Task.isCancelled, let page else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        page: page,
                        position: Self.webPosition(seed),
                        error: nil
                    )
                }
                var delivered = 0
                for try await location in updates {
                    guard !Task.isCancelled, let page else { return }
                    await self?.deliverPosition(
                        requestID: requestID,
                        page: page,
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
                guard !Task.isCancelled, let page else { return }
                await self?.deliverPosition(
                    requestID: requestID,
                    page: page,
                    position: nil,
                    error: Self.webPositionError(error)
                )
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "configuration",
                    message: "a watched position failed (watch \(requestID)): \(String(reflecting: error))"
                )
            }
        }
    }

    /// What the shim's `XMLHttpRequest` hands over.
    private struct ScriptRequest {
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
    private func answerScriptRequest(_ script: ScriptRequest, page: WKWebView) async {
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
    private static let scriptResponseLimit = 10 * 1_024 * 1_024

    /// Nil when the answer is not HTTP or runs past `limit`. Counted as the
    /// bytes arrive rather than read whole with `data(for:)` and measured
    /// after: a body that gives no length is bounded by nothing until it has
    /// all been held.
    ///
    /// `@concurrent` so the millions of iterations a large body takes run off
    /// the main actor; a plain `nonisolated` function would run on its
    /// caller's, which is the main actor, under `NonisolatedNonsendingByDefault`.
    @concurrent
    private static func fetchBody(
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

    private func scriptSession(for applicationID: UUID) -> URLSession {
        if let session = scriptSessions[applicationID] { return session }
        let session = URLSession(configuration: .ephemeral)
        scriptSessions[applicationID] = session
        return session
    }

    /// The body as the response's own charset says, then as UTF-8, then as
    /// Latin-1, which reads any bytes at all.
    private static func text(of data: Data, encodingName: String?) -> String {
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
    private func deliverScriptResponse(
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

    /// The page is going or gone: nobody is left to deliver positions to.
    private func cancelPositionWatchers() {
        for watcher in positionWatchers.values { watcher.cancel() }
        positionWatchers = [:]
    }

    /// Answers a script's request for a position, in the shape the web has for
    /// one so that a script written against a browser reads it unchanged.
    private func answerPosition(requestID: Int, page: WKWebView) async {
        do {
            let location = try await locationHandler()
            await deliverPosition(requestID: requestID, page: page, position: Self.webPosition(location), error: nil)
        } catch {
            await deliverPosition(requestID: requestID, page: page, position: nil, error: Self.webPositionError(error))
            await DiagnosticLog.shared.record(
                .warning,
                category: "configuration",
                message: "an application asked for a position and did not get one:"
                    + " \(String(reflecting: error))"
            )
        }
    }

    /// The page that asked, not whichever page is up now: a page built since
    /// numbers its requests from one again, and would take the answer to
    /// another page's question as the answer to its own.
    private func deliverPosition(
        requestID: Int,
        page: WKWebView,
        position: [String: Any]?,
        error: [String: Any]?
    ) async {
        guard let webView, webView === page else { return }
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

    /// A `GeolocationPositionError`. The codes are the web's: 1 refused, 2
    /// could not be found, 3 took too long. Refused is the one worth telling
    /// apart — the reader can do something about it, and the others they
    /// cannot.
    private static func webPositionError(_ error: any Error) -> [String: Any] {
        let refused = (error as? WeatherSourceError) == .locationNotAllowed
        return [
            "code": refused ? 1 : 2,
            "message": refused
                ? "Pebble has not been allowed your position."
                : "Your position could not be found.",
        ]
    }

    private func resolve(callbackID: Int, succeeded: Bool, page: WKWebView) async throws {
        guard let webView, webView === page else { throw CompanionRuntimeError.noApplicationLoaded }
        _ = try await webView.callAsyncJavaScript(
            "window.__pebbleResult(id, ok);",
            arguments: ["id": callbackID, "ok": succeeded],
            in: nil,
            contentWorld: .page
        )
    }

    /// A script's value as a tuple, in the official runtime's order
    /// (`PKJSApp.kt` `toAppMessageData`): a string, then a whole number that
    /// fits a signed 32-bit integer as signed, a larger one as unsigned, and
    /// a fraction cut toward zero. Everything non-negative as unsigned was the
    /// same bytes but another tuple type, which an app checking
    /// `tuple->type == TUPLE_INT` refuses.
    private static func appMessageValue(_ value: Any) -> AppMessageValue? {
        switch value {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            let number = value.doubleValue
            guard number.isFinite else { return nil }
            let whole = number.rounded(.towardZero)
            if let signed = Int32(exactly: whole) { return .signed(signed) }
            if whole == number, let long = Int64(exactly: whole) {
                return .unsigned(UInt32(truncatingIfNeeded: long))
            }
            return .signed(whole < 0 ? .min : .max)
        case let values as [Any]:
            // Wrapped per byte, as `toUByte()` does: casting the array to
            // `[UInt8]` failed on one element out of range and lost the tuple.
            var bytes: [UInt8] = []
            for element in values {
                guard let number = (element as? NSNumber)?.doubleValue,
                      let long = Int64(exactly: number) else { return nil }
                bytes.append(UInt8(truncatingIfNeeded: long))
            }
            return .bytes(bytes)
        default:
            return nil
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

    /// The host a loaded application's page runs on, which is both where the
    /// page is loaded from and the only origin its messages are taken from.
    private static func originHost(of applicationID: UUID) -> String {
        "\(applicationID.uuidString.lowercased()).pebble.local"
    }

    /// `Pebble.getActiveWatchInfo()`, as an object literal.
    ///
    /// The platform is the variant installed, not the watch's own: a script
    /// written for basalt alone branches on the names it knows, and handed
    /// "emery" takes none of them (`PrivatePKJSInterface.kt`
    /// `getActivePebbleWatchInfo`).
    private static func watchInfoLiteral(
        for watch: ConnectedWatch?,
        running application: WatchApplication
    ) throws -> String {
        let info = ScriptWatchInfo(
            platform: watch?.model.map {
                (application.bestVariant(for: $0) ?? $0.platform).rawValue
            } ?? "unknown",
            model: watch?.model?.rawValue ?? "unknown",
            language: watch.map { $0.languageLocale.isEmpty ? "en_US" : $0.languageLocale } ?? "en_US",
            firmware: ScriptWatchInfo.Firmware(watch?.firmwareVersion)
        )
        let data = try JSONEncoder().encode(info)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return literal
    }
}

private struct ScriptWatchInfo: Encodable {
    struct Firmware: Encodable {
        var major = 0
        var minor = 0
        var patch = 0
        var suffix = ""

        /// `v4.36.2-rc1` as its numbers, the way the official runtime reads the
        /// tag (`FIRMWARE_VERSION_REGEX` in `SystemService.kt`). Zeros with the
        /// whole tag as the suffix made every `firmware.major >= 4` false.
        init(_ tag: String?) {
            guard let tag,
                  let match = tag.firstMatch(of: /v?([0-9]+)\.([0-9]+)(?:\.([0-9]+))?(?:-(.*))?/) else { return }
            major = Int(match.1) ?? 0
            minor = Int(match.2) ?? 0
            patch = match.3.flatMap { Int($0) } ?? 0
            suffix = match.4.map(String.init) ?? ""
        }
    }

    var platform: String
    var model: String
    var language: String
    var firmware: Firmware
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
