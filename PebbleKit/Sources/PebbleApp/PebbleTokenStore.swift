import PebbleProtocol
import Foundation
import Valet

/// PebbleKit JS gives a configuration page an account token, stable for the
/// user, and a watch token, stable for the watch.
struct PebbleTokenStore {
    /// Nil for an empty identifier, which Valet cannot name a keychain after;
    /// the tokens are then made fresh each time, as without a keychain.
    private let valet: Valet?

    init(identifier: String = "dev.pebble.companion.tokens") {
        // A token that survived to a restored watch would identify the old install.
        valet = Identifier(nonEmpty: identifier).map {
            Valet.valet(with: $0, accessibility: .whenUnlockedThisDeviceOnly)
        }
    }

    func token(named name: String) -> String {
        guard let valet else {
            return UserDefaults.standard.string(forKey: name) ?? Self.makeToken()
        }
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

    static func watchTokenName(watchID: WatchID) -> String {
        "pebbleWatchToken.\(watchID)"
    }

    private static func makeToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
