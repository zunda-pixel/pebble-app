public import Foundation
import MemberwiseInit
import Retry

/// One language pack published for a board.
@MemberwiseInit(.public)
public struct PebbleLanguagePack: Equatable, Identifiable, Sendable {
    /// The locale as the firmware spells it, which is also what a watch reports
    /// back once the pack is installed: `fr_FR`, `en_CN`.
    public var locale: String
    /// The language's name in itself, which is how it should be read.
    public var localName: String
    /// The board the pack was built for, as the pack list names it, or nil for
    /// one built to suit any board. A pack is compiled against a display and a
    /// font set, so a board-specific one is not interchangeable — and the list
    /// covers boards this app never connects to, which is why this is a name
    /// rather than a `PebbleWatchBoard`.
    public var boardName: String?
    public var version: UInt16
    public var url: URL

    /// Two packs can share a locale — Japanese comes in two font weights — so
    /// what identifies one is where it comes from.
    public var id: String { url.absoluteString }
}

/// The language packs this app knows how to fetch.
///
/// There is no service to ask: the official app carries the same list compiled
/// in, pointing at Rebble's public binaries and, for Arabic, a GitHub release.
/// Nothing here needs credentials.
public struct PebbleLanguagePackCatalog: Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The packs on offer for a board, in the order they should be read.
    ///
    /// Only Arabic is built for the current boards. Every other language comes
    /// either from a pack built for any board or from the Pebble 2's (silk),
    /// which is what the official app does too: the boards share enough of
    /// their display and fonts for those packs to work, and offering nothing
    /// would be worse. A locale the board itself provides is not offered twice.
    public static func packs(for board: PebbleWatchBoard) -> [PebbleLanguagePack] {
        let exact = all.filter { $0.boardName == board.rawValue }
        let exactLocales = Set(exact.map(\.locale))
        let fallback = all.filter { pack in
            (pack.boardName == nil || pack.boardName == silkBoardName)
                && !exactLocales.contains(pack.locale)
        }
        return (exact + fallback).sorted { $0.localName < $1.localName }
    }

    /// Downloads a pack, ready to be sent to the watch.
    public func download(_ pack: PebbleLanguagePack) async throws -> Data {
        let url = try await retry(with: .networkFetch) {
            do {
                return try await downloadFile(from: pack.url, using: session)
            } catch HTTPFileDownloadError.insecureURL {
                throw NotRetryable(PebbleLanguagePackError.insecureURL)
            } catch let error as HTTPFileDownloadError {
                throw error.isWorthAnotherAttempt
                    ? PebbleLanguagePackError.unavailable
                    : NotRetryable(PebbleLanguagePackError.unavailable)
            } catch {
                throw PebbleLanguagePackError.unavailable
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw PebbleLanguagePackError.unavailable }
        return data
    }

    /// The name the firmware files a language pack under. Sending it under any
    /// other name stores a file the watch will never read.
    public static var filename: String { "lang" }

    /// The Pebble 2's board, whose packs stand in for boards that have none of
    /// their own.
    static let silkBoardName = "silk"

    static let all: [PebbleLanguagePack] = {
        // Arabic is the one language built for the current boards, and the same
        // package covers all of them.
        let arabic = URL(string: "https://github.com/kaluaim/PebbleOS/releases/download/ar_SA-v1/ar_SA.pbl")!
        let arabicBoards: [PebbleWatchBoard] = [
            .asterix, .obelixEVT, .obelixDVT, .obelixPVT, .getafixEVT, .getafixDVT, .getafixDVT2,
        ]
        // Packs built to suit any board, which is where Japanese, Hebrew,
        // Bulgarian and Catalan come from. Japanese has two font weights, so it
        // appears twice on purpose.
        let anyBoard: [(String, String, UInt16, String)] = [
            ("ja_JP", "日本語", 5, "https://github.com/elliottback/PebbleTimeJapaneseLanguagePack/raw/1e914c39dc459c03ce8a1ae6ee7c17f59f56f21c/pblp_zhs_zht_ja_v5_regular.pbl"),
            ("ja_JP", "日本語（細字）", 5, "https://github.com/elliottback/PebbleTimeJapaneseLanguagePack/raw/1e914c39dc459c03ce8a1ae6ee7c17f59f56f21c/pblp_zhs_zht_ja_v5_light.pbl"),
            ("he_IL", "עברית", 1, "https://github.com/alonmln/PebbleOS/releases/download/he_IL-v1/he_IL.pbl"),
            ("bg", "български", 1, "https://github.com/MarSoft/pebble-firmware-utils/raw/builds/langs/Bulgarian-v1.pbl"),
            ("ca", "català", 1, "https://github.com/MarSoft/pebble-firmware-utils/raw/builds/langs/Catalan-v1.pbl"),
        ]
        let silk: [(String, String, UInt16, String)] = [
            ("de_DE", "Deutsch", 34, "Vzq58DE-de_DE.pbl"),
            ("en_US", "English", 1, "960sGtg-en_US.pbl"),
            ("es_ES", "Español", 34, "QKYD6CQ-es_ES.pbl"),
            ("fr_FR", "Français", 38, "gIfNRlM-fr_FR.pbl"),
            ("it_IT", "Italiano", 21, "HPECY6i-it_IT.pbl"),
            ("pt_PT", "Português", 19, "vCoHVfL-pt_PT.pbl"),
            ("ru_RU", "Кириллица", 3, "ywAw1NK-ru_RU.pbl"),
            ("en_CN", "简体通知", 2, "EDJQTJm-en_CN.pbl"),
            ("en_TW", "繁體通知", 1, "dGKVKJA-en_TW.pbl"),
            ("en_MY", "မြန်မာစာ", 1, "myanmar.pbl"),
        ]
        return arabicBoards.map { board in
            PebbleLanguagePack(
                locale: "ar_SA",
                localName: "العربية",
                boardName: board.rawValue,
                version: 1,
                url: arabic
            )
        } + anyBoard.map { locale, name, version, url in
            PebbleLanguagePack(
                locale: locale,
                localName: name,
                boardName: nil,
                version: version,
                url: URL(string: url)!
            )
        } + silk.map { locale, name, version, file in
            PebbleLanguagePack(
                locale: locale,
                localName: name,
                boardName: silkBoardName,
                version: version,
                url: URL(string: "https://binaries.rebble.io/lp/\(file)")!
            )
        }
    }()
}

public enum PebbleLanguagePackError: Error, Equatable, Sendable {
    case unavailable
    case insecureURL
    /// The watch says it does not take language packs, so sending one would
    /// only waste the transfer.
    case unsupportedByWatch
}
