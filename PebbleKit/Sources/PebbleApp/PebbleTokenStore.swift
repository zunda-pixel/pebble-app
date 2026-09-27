import CryptoKit
import PebbleProtocol
import Foundation
import Valet

/// PebbleKit JS gives a configuration page an account token, stable for the
/// user, and a watch token, stable for the watch — each one different for
/// every developer, so two developers' pages cannot match the reader up.
struct PebbleTokenStore {
    /// Nil for an empty identifier, which Valet cannot name a keychain after;
    /// the account seed is then made fresh each time, as without a keychain.
    private let valet: Valet?

    init(identifier: String = "dev.pebble.companion.tokens") {
        // A seed that survived to a restored phone would identify the old install.
        valet = Identifier(nonEmpty: identifier).map {
            Valet.valet(with: $0, accessibility: .whenUnlockedThisDeviceOnly)
        }
    }

    /// Seeded with a secret of this install's, where the official app seeds
    /// it with the reader's cloud account, which this app does not have.
    func accountToken(applicationID: UUID, developerID: String? = nil) -> String {
        Self.token(seed: accountSeed(), applicationID: applicationID, developerID: developerID)
    }

    /// Seeded with the watch's serial, as the official app does, so a page
    /// sees the same watch token for the same watch from either app. The
    /// phone's identifier for the watch changes when it is paired again.
    func watchToken(applicationID: UUID, developerID: String? = nil, watch: ConnectedWatch?) -> String {
        let seed = watch?.serialNumber ?? watch?.id.rawValue ?? ""
        return Self.token(seed: seed, applicationID: applicationID, developerID: developerID)
    }

    /// `JsTokenUtil.generateToken`: the lowercase hex MD5 of the seed, the
    /// developer's identifier — or the app's UUID in upper case where there is
    /// none — and the official app's salt.
    static func token(seed: String, applicationID: UUID, developerID: String?) -> String {
        let input = seed + (developerID ?? applicationID.uuidString.uppercased()) + salt
        return Insecure.MD5.hash(data: Data(input.utf8)).hexadecimalString
    }

    private static let salt = "MMIxeUT[G9/U#(7V67O^EuADSw,{$C;B}`>|-nlrQCs|t|k=P_!*LETm,RKc,BG*'"

    private static let accountSeedName = "accountTokenSeed"

    private func accountSeed() -> String {
        guard let valet else { return Self.makeSeed() }
        if let existing = try? valet.string(forKey: Self.accountSeedName) {
            return existing
        }
        let seed = Self.makeSeed()
        // Without the keychain the page still needs a token; it just will not
        // be the same one next time.
        try? valet.setString(seed, forKey: Self.accountSeedName)
        return seed
    }

    private static func makeSeed() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
