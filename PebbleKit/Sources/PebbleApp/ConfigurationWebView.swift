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
            do {
                // A page the application's own JavaScript built is unpacked and
                // handed over as HTML: WebKit refuses to navigate to a `data:`
                // URL at the top level, so loading it as one shows nothing.
                if let html = url.inlineHTML {
                    for try await _ in page.load(html: html, baseURL: Self.inlineBaseURL) {}
                } else {
                    for try await _ in page.load(url) {}
                }
            } catch {
                if let urlError = error as? URLError, urlError.code == .cannotFindHost {
                    loadErrorMessage = "The watch app's settings service could not be found."
                } else {
                    loadErrorMessage = "The watch app's settings page could not be loaded."
                }
            }
        }
    }
}

#Preview {
    ContentView(client: MockWatchClient())
}
