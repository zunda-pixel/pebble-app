import SwiftUI
import API
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
        return url.scheme?.lowercased() == "https" ? .allow : .cancel
    }
}

struct ConfigurationWebView: View {
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
                for try await _ in page.load(url) {}
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
    ContentView(client: MockPebbleClient())
}
