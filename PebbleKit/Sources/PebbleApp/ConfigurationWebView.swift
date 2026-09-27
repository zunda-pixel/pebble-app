import Foundation
import SwiftUI
import PebbleProtocol
import PebbleTransport
import WebKit

struct ConfigurationNavigationDecider: WebPage.NavigationDeciding {
    var closeHandler: @MainActor @Sendable (String?) -> Void

    mutating func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        if url.scheme?.lowercased() == "pebblejs", url.host?.lowercased() == "close" {
            let encodedResponse = url.fragment ?? url.query
            closeHandler(encodedResponse?.removingPercentEncoding ?? encodedResponse)
            return .cancel
        }
        // The base a page handed over inline is loaded against. It is not a
        // page being navigated to and there is nothing to weigh up about it.
        if url == ConfigurationWebView.inlineBaseURL { return .allow }
        // The same schemes the page was opened under. Refusing `http` here as
        // well as there meant a page allowed through one gate was cancelled by
        // the other, which read as a settings page that would not load.
        return AppModel.mayOpenConfigurationURL(url) ? .allow : .cancel
    }
}

struct ConfigurationWebView: View {
    /// What a page handed over inline is loaded against. Relative links in a
    /// self-contained settings page have nothing to resolve to, which is the
    /// truth of it rather than a limitation.
    static let inlineBaseURL = URL(literal: "about:blank")

    var url: URL
    var closeHandler: @MainActor @Sendable (String?) -> Void
    /// Made when the page is loaded rather than when the view is built.
    ///
    /// A `@State` initial value is *written* once per identity but the
    /// expression behind it runs on every body pass, and this one built a
    /// `WebPage` — a whole web content process — each time, only for all but
    /// the first to be thrown away. SwiftUI builds this view more than once per
    /// opening: five identities came out of three openings on the reader's
    /// phone. The discarded ones left `Failed to initialize application
    /// enviroment context` behind them and the page that was on screen took
    /// 9.7 seconds without ever finishing, against 0.83 for one that opened
    /// alone.
    @State private var page: WebPage?
    @State private var loadErrorMessage: LocalizedStringKey?
    /// Which of these views is loading. A `@State` initial value is taken once
    /// per identity, so this is what said the page was being loaded by two
    /// views rather than by one view starting over.
    @State private var identity = UUID()

    // Spelled out because the `@State` properties are private, which would make
    // the synthesized one unreachable from the screen that presents this.
    init(url: URL, closeHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        self.url = url
        self.closeHandler = closeHandler
    }

    var body: some View {
        Group {
            if let loadErrorMessage {
                ConfigurationUnavailableView(message: loadErrorMessage)
            } else if let page {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
            } else {
                // The moment before the web view exists, which is this side of
                // the first body pass rather than anything being waited on.
                ProgressView()
            }
        }
        .task(id: url) {
            loadErrorMessage = nil
            // Built here, so the one the reader ends up looking at is the only
            // one that was ever made — and around the current `closeHandler`
            // rather than whichever one the first body pass happened to carry.
            let page = self.page ?? WebPage(
                navigationDecider: ConfigurationNavigationDecider(closeHandler: closeHandler)
            )
            self.page = page
            // The kind, and then how it went. Whether a settings page appeared
            // was the one thing about it that never reached the log, so a page
            // the app agreed to open and the web view then refused looked from
            // the outside exactly like one that worked.
            let inlineHTML = url.inlineHTML
            await DiagnosticLog.shared.record(
                category: "configuration",
                message: "[\(identity.uuidString.prefix(8))] "
                    + (inlineHTML.map { "loading \($0.utf8.count) byte(s) of page the application built" }
                        ?? "loading a page over \(url.scheme ?? "no scheme")")
            )
            do {
                // A page the application's own JavaScript built is unpacked and
                // handed over as HTML: WebKit refuses to navigate to a `data:`
                // URL at the top level, so loading it as one shows nothing.
                if let inlineHTML {
                    for try await _ in page.load(html: inlineHTML, baseURL: Self.inlineBaseURL) {}
                } else {
                    for try await _ in page.load(url) {}
                }
                // A load nobody is waiting for any more ends here too: the task
                // is cancelled when its view goes, and the sequence finishes
                // rather than throwing. Saying it is up would date the page
                // from a load that was given up on — 5.5 seconds before the one
                // the reader actually saw, on the reader's phone.
                guard !Task.isCancelled else {
                    await DiagnosticLog.shared.record(
                        category: "configuration",
                        message: "[\(identity.uuidString.prefix(8))]"
                            + " this view went before its page was up"
                    )
                    return
                }
                await DiagnosticLog.shared.record(
                    category: "configuration",
                    message: "[\(identity.uuidString.prefix(8))] the settings page is up"
                )
            } catch {
                if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                    loadErrorMessage = "The watch app's settings service could not be found."
                } else {
                    loadErrorMessage = "The watch app's settings page could not be loaded."
                }
                await DiagnosticLog.shared.record(
                    .error,
                    category: "configuration",
                    message: "[\(identity.uuidString.prefix(8))]"
                        + " the settings page would not load: \(String(reflecting: error))"
                )
            }
        }
    }
}

/// What the screen says when a settings page cannot be shown.
struct ConfigurationUnavailableView: View {
    var message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView(
            "Settings Unavailable",
            systemImage: "wifi.exclamationmark",
            description: Text(message)
        )
    }
}

#Preview("A page the application built") {
    // The inline `data:` route, the way AgroWeatherApp hands its settings over.
    ConfigurationWebView(
        url: URL(
            string: "data:text/html,<h1>Clock Settings</h1><p>Choose what the face shows.</p>"
        )!
    ) { _ in }
}

#Preview("A page that would not load") {
    // Previewed on its own: from the whole screen this state is only reachable
    // by a network failing, which a snapshot does not wait for.
    ConfigurationUnavailableView(
        message: "The watch app's settings service could not be found."
    )
}
