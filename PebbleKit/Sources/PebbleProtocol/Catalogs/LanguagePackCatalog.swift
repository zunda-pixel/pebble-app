public import Foundation
import MemberwiseInit
import Retry

@MemberwiseInit(.public)
public struct LanguagePack: Equatable, Identifiable, Sendable {
    /// As the firmware spells it, which is also what a watch reports back once
    /// the pack is installed: `fr_FR`, `en_CN`.
    public var locale: String
    public var localName: String
    /// Nil for a pack built to suit any board. A pack is compiled against a
    /// display and a font set, so a board-specific one is not interchangeable.
    public var boardName: String?
    public var version: UInt16
    public var url: URL

    public var id: String { url.absoluteString }
}

/// There is no service to ask: the official app carries the same list compiled
/// in, pointing at Rebble's public binaries.
public struct LanguagePackCatalog: Sendable {
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

    /// Only Arabic is built for the current boards; every other language comes
    /// from a pack built for any board or from the Pebble 2's.
    public static func packs(for board: WatchBoard) -> [LanguagePack] {
        let exact = all.filter { $0.boardName == board.rawValue }
        let exactLocales = Set(exact.map(\.locale))
        let fallback = all.filter { pack in
            (pack.boardName == nil || pack.boardName == silkBoardName)
                && !exactLocales.contains(pack.locale)
        }
        return (exact + fallback).sorted { $0.localName < $1.localName }
    }

    public func download(_ pack: LanguagePack) async throws -> Data {
        let url = try await retry(with: .networkFetch) {
            do {
                return try await downloadFile(from: pack.url, using: session)
            } catch HTTPFileDownloadError.insecureURL {
                throw NotRetryable(LanguagePackError.insecureURL)
            } catch let error as HTTPFileDownloadError {
                throw error.isWorthAnotherAttempt
                    ? LanguagePackError.unavailable
                    : NotRetryable(LanguagePackError.unavailable)
            } catch {
                throw LanguagePackError.unavailable
            }
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard try downloadedFileSize(at: url) <= Self.maximumPackSize else {
            throw LanguagePackError.packTooLarge
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw LanguagePackError.unavailable }
        return data
    }

    /// Sending a pack under any other name stores a file the watch never reads.
    public static var filename: String { "lang" }

    static let maximumPackSize = 16 * 1_024 * 1_024

    static let silkBoardName = "silk"

    static let all: [LanguagePack] = {
        // The one language built for the current boards, and the same package covers
        // all of them.
        let arabic = URL(string: "https://github.com/kaluaim/PebbleOS/releases/download/ar_SA-v1/ar_SA.pbl")!
        let arabicBoards: [WatchBoard] = [
            .asterix, .obelixEVT, .obelixDVT, .obelixPVT, .getafixEVT, .getafixDVT, .getafixDVT2,
        ]
        // Japanese has two font weights, so it appears twice on purpose.
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
            LanguagePack(
                locale: "ar_SA",
                localName: "العربية",
                boardName: board.rawValue,
                version: 1,
                url: arabic
            )
        } + anyBoard.map { locale, name, version, url in
            LanguagePack(
                locale: locale,
                localName: name,
                boardName: nil,
                version: version,
                url: URL(string: url)!
            )
        } + silk.map { locale, name, version, file in
            LanguagePack(
                locale: locale,
                localName: name,
                boardName: silkBoardName,
                version: version,
                url: URL(string: "https://binaries.rebble.io/lp/\(file)")!
            )
        }
    }()
}

public enum LanguagePackError: Error, Equatable, Sendable {
    case unavailable
    case insecureURL
    case packTooLarge
}
