import CoreLocation
import PebbleProtocol
import Foundation
import WebKit

@MainActor
final class PebbleCompanionRuntime: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// Made per application, because the store it keeps its settings in is
    /// named after the application and a `WKWebView` takes its store when it is
    /// built.
    var webView: WKWebView?
    var application: WatchApplication?
    private let openURLHandler: (URL) -> Void
    private let appMessageHandler: (UUID, [AppMessageTuple]) async throws -> Void
    private let notificationHandler: (WatchApplication, String, String) async -> Void
    private let activeWatchHandler: () -> ConnectedWatch?
    let locationHandler: () async throws -> CLLocation
    /// A live stream of positions for `watchPosition`, or a throw where the
    /// phone has not been allowed to know. Throwing is the gate that keeps a
    /// script's request from ever raising the OS permission dialog itself.
    let locationUpdatesHandler: @MainActor () throws -> AsyncThrowingStream<CLLocation, any Error>
    /// A pin a script pushed, and the one it took back — owned by the
    /// application whose script said so.
    private let timelinePinInsertHandler: (CompanionTimelinePin, UUID) async -> Void
    private let timelinePinDeleteHandler: (String, UUID) async -> Void
    /// The launcher line a script reloaded, owned by the running application.
    /// Answers whether it was saved, which is what the script's callback says.
    private let appGlanceReloadHandler: ([AppGlanceSlice], UUID) async -> Bool
    /// One task per `watchPosition` call, keyed by the script's own watch id,
    /// cancelled by `clearWatch` and when the page goes away.
    var positionWatchers: [Int: Task<Void, Never>] = [:]
    /// Each application's own session for its script's requests, as the web
    /// view's store is. Sharing `URLSession.shared` sent a cookie one app was
    /// handed along with every other app's requests. Ephemeral: a script's
    /// cookies were never meant to outlive the process any more than a page's.
    var scriptSessions: [UUID: URLSession] = [:]
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
        let html = Self.pageHTML(
            watchInfo: watchInfo,
            accountTokenLiteral: accountTokenLiteral,
            watchTokenLiteral: watchTokenLiteral,
            identifierLiteral: identifierLiteral,
            sourceLiteral: sourceLiteral
        )
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
