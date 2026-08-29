import Foundation
import Valet

/// The identifiers handed to a watch app's configuration page.
///
/// PebbleKit JS gives a configuration page an account token, stable for the
/// user, and a watch token, stable for that app on that watch. They identify
/// someone across every configuration page they open, so they live in the
/// keychain rather than in a preferences plist that backups and syncs copy in
/// the clear.
struct PebbleTokenStore {
    private let valet: Valet

    init(identifier: String = "dev.pebble.companion.tokens") {
        // A token is only useful while the app runs, and one that survives to
        // a restored device would identify the old install.
        valet = Valet.valet(
            with: Identifier(nonEmpty: identifier)!,
            accessibility: .whenUnlockedThisDeviceOnly
        )
    }

    /// The token stored under a name, minted and kept on first use.
    func token(named name: String) -> String {
        if let existing = try? valet.string(forKey: name) {
            return existing
        }
        // These tokens used to live in preferences. Reissuing one would change
        // the identity every configuration page sees, so an existing token is
        // carried over rather than replaced.
        let token = UserDefaults.standard.string(forKey: name) ?? Self.makeToken()
        do {
            try valet.setString(token, forKey: name)
            UserDefaults.standard.removeObject(forKey: name)
        } catch {
            // Without the keychain the page still needs a token; it just will
            // not be the same one next time.
            return token
        }
        return token
    }

    /// The name the account token is stored under.
    static var accountTokenName: String { "pebbleAccountToken" }

    /// The name a watch's token is stored under.
    static func watchTokenName(watchID: String) -> String {
        "pebbleWatchToken.\(watchID)"
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
