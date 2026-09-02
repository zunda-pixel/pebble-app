import Foundation
import Valet

/// PebbleKit JS gives a configuration page an account token, stable for the
/// user, and a watch token, stable for the watch.
struct PebbleTokenStore {
    private let valet: Valet

    init(identifier: String = "dev.pebble.companion.tokens") {
        // A token that survived to a restored device would identify the old install.
        valet = Valet.valet(
            with: Identifier(nonEmpty: identifier)!,
            accessibility: .whenUnlockedThisDeviceOnly
        )
    }

    func token(named name: String) -> String {
        if let existing = try? valet.string(forKey: name) {
            return existing
        }
        // These tokens used to live in preferences. Reissuing one would change the
        // identity every configuration page sees.
        let token = UserDefaults.standard.string(forKey: name) ?? Self.makeToken()
        do {
            try valet.setString(token, forKey: name)
            UserDefaults.standard.removeObject(forKey: name)
        } catch {
            // Without the keychain the page still needs a token; it just will not be the
            // same one next time.
            return token
        }
        return token
    }

    static var accountTokenName: String { "pebbleAccountToken" }

    static func watchTokenName(watchID: String) -> String {
        "pebbleWatchToken.\(watchID)"
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
