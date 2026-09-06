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
    static let inlineBaseURL = URL(string: "about:blank")!

    var url: URL
    var closeHandler: @MainActor @Sendable (String?) -> Void
    @State private var page: WebPage
    @State private var loadErrorMessage: String?
    /// Which of these views is loading, so a page loaded twice can say whether
    /// that was one view starting over or two views racing.
    ///
    /// A `@State` initial value is taken once per identity, so two identities
    /// carry two of these and one identity carries one however often its body
    /// runs. That is the difference the log could not see: the second load runs
    /// to the end while the first is thrown away, and whichever web view is on
    /// screen is the one that never finishes.
    @State private var identity = UUID()

    init(url: URL, closeHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        self.url = url
        self.closeHandler = closeHandler
        _page = State(initialValue: WebPage(
            navigationDecider: ConfigurationNavigationDecider(closeHandler: closeHandler)
        ))
    }

    var body: some View {
        Group {
            if let loadErrorMessage {
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "wifi.exclamationmark",
                    description: Text(loadErrorMessage)
                )
            } else {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
            }
        }
        .task(id: url) {
            loadErrorMessage = nil
            // The kind, and then how it went. Whether a settings page appeared
            // was the one thing about it that never reached the log, so a page
            // the app agreed to open and the web view then refused looked from
            // the outside exactly like one that worked.
            let inlineHTML = url.inlineHTML
            await PebbleDiagnostics.shared.record(
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
                // A load that was superseded ends here too: `.task(id:)` cancels
                // the one before it, and the sequence finishes rather than
                // throwing. Saying it is up would date the page from the load
                // that was given up on — 5.5 seconds before the one the reader
                // actually saw, on the reader's phone.
                guard !Task.isCancelled else {
                    await PebbleDiagnostics.shared.record(
                        category: "configuration",
                        message: "[\(identity.uuidString.prefix(8))]"
                            + " a second page took over before this one was up"
                    )
                    return
                }
                await PebbleDiagnostics.shared.record(
                    category: "configuration",
                    message: "[\(identity.uuidString.prefix(8))] the settings page is up"
                )
            } catch {
                if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                    loadErrorMessage = "The watch app's settings service could not be found."
                } else {
                    loadErrorMessage = "The watch app's settings page could not be loaded."
                }
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "configuration",
                    message: "[\(identity.uuidString.prefix(8))]"
                        + " the settings page would not load: \(String(reflecting: error))"
                )
            }
        }
    }
}

#Preview {
    ContentView(client: MockWatchClient())
}
