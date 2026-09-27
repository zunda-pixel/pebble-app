public import Foundation

extension URL {
    /// The page a `data:` URL carries, if it carries one.
    ///
    /// A watch application's settings page need not be on a server: the
    /// companion JavaScript can build the whole thing and hand it over as
    /// `Pebble.openURL('data:text/html,…')`, which is what AgroWeatherApp does
    /// and what was refused here as a URL with no host. WebKit will not
    /// navigate to a `data:` URL at the top level, so the HTML has to come out
    /// and be given to the web view directly.
    ///
    /// Nil for anything that is not a `data:` URL, and for one whose media type
    /// says it is not a page — an image or a PDF is not a settings screen, and
    /// rendering it as markup would be a guess. An absent media type is taken
    /// as a page: `RFC 2397` calls that `text/plain`, and applications leave it
    /// off while sending markup all the same.
    public var inlineHTML: String? {
        guard scheme?.lowercased() == "data" else { return nil }
        // Read from the whole string: `URL` does not break a `data:` URL into
        // parts, and the payload may hold anything including `#` and `?`.
        let text = absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: "data:".count)..<comma]
        let payload = String(text[text.index(after: comma)...])

        var parameters = header.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let isBase64 = parameters.last == "base64"
        if isBase64 { parameters.removeLast() }
        let mediaType = parameters.first ?? ""
        guard mediaType.isEmpty || mediaType == "text/html" || mediaType == "text/plain" else {
            return nil
        }

        let html: String?
        if isBase64 {
            // Unknown characters are ignored because base64 in a URL arrives
            // wrapped and padded in whatever way the application chose; one
            // that is not base64 at all falls out as nothing, which the
            // emptiness check below refuses.
            // Decoded first: a script that ran it through `encodeURIComponent`
            // sends `+`, `/` and `=` as `%2B`, `%2F` and `%3D`, and only the `%`
            // would be ignored.
            html = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            // Percent-encoding is how the markup survives being a URL at all.
            html = payload.removingPercentEncoding ?? payload
        }
        // A page with nothing in it is not a page: loading it would leave a
        // blank web view with nothing to say about why.
        guard let html, !html.isEmpty else { return nil }
        return html
    }
}
