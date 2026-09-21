public import Foundation
import HTTPTypes
import HTTPTypesFoundation
import MemberwiseInit
import Retry

@MemberwiseInit(.public)
public struct DownloadedFirmware: Codable, Equatable, Sendable {
    public var versionTag: String
    public var board: WatchBoard
    public var url: URL
}

@MemberwiseInit(.public)
public struct PebbleOSFirmwareRelease: Equatable, Sendable {
    public var versionTag: String
    public var board: WatchBoard
    public var downloadURL: URL
    public var sizeInBytes: Int
    public var releaseNotesURL: URL?
}

/// PebbleOS publishes a package per board with every release, and the download
/// needs no credentials.
public struct PebbleOSFirmwareCatalog: Sendable {
    // Assets are named `normal_<board>_<version>.pbz`. A dual-slot board also
    // publishes `_slot0`/`_slot1` variants; the plain one holds both.
    static let assetPrefix = "normal_"

    private let releasesURL: URL
    private let session: URLSession

    public init(
        releasesURL: URL = URL(string: "https://api.github.com/repos/coredevices/PebbleOS/releases?per_page=100")!,
        session: URLSession? = nil
    ) {
        self.releasesURL = releasesURL
        if let session {
            self.session = session
        } else {
            // A firmware package is megabytes; the default request timeout is not enough
            // on a slow link.
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    public func latestRelease(for board: WatchBoard) async throws -> PebbleOSFirmwareRelease {
        try await retry(with: .networkFetch) {
            let request = HTTPRequest(
                method: .get,
                url: releasesURL,
                headerFields: [.accept: "application/vnd.github+json"]
            )
            let (data, response) = try await session.data(for: request)
            guard response.status == .ok else {
                let error = PebbleOSFirmwareCatalogError.releasesUnavailable
                throw response.status.isWorthAnotherAttempt ? error : NotRetryable(error)
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            // The highest version with a package for this board, never the
            // newest date. PebbleOS ships patches for its older lines after
            // newer releases — v4.27.3 arrived six releases after v4.37.0
            // (measured 2026-09-21) — so GitHub's own `latest`, which is a
            // date, answered a downgrade and hid the real update (#124).
            let candidates = releases
                .filter { $0.prerelease != true && $0.draft != true }
                .compactMap { release -> PebbleOSFirmwareRelease? in
                    guard let asset = Self.asset(for: board, in: release.assets) else { return nil }
                    return PebbleOSFirmwareRelease(
                        versionTag: release.tagName,
                        board: board,
                        downloadURL: asset.browserDownloadURL,
                        sizeInBytes: asset.size,
                        releaseNotesURL: release.htmlURL
                    )
                }
            guard let newest = candidates.max(by: {
                Self.isVersion($1.versionTag, newerThan: $0.versionTag)
            }) else {
                // Asking again returns the same list.
                throw NotRetryable(PebbleOSFirmwareCatalogError.noFirmwareForBoard(board))
            }
            return newest
        }
    }

    /// Numeric and component-wise: "v4.37.0" beats "v4.30.3" however their
    /// dates fall, and "v4.9.142.4" sits below both because 9 < 30.
    public static func isVersion(_ candidate: String, newerThan running: String) -> Bool {
        func bare(_ version: String) -> String {
            version.hasPrefix("v") ? String(version.dropFirst()) : version
        }
        return bare(candidate).compare(bare(running), options: .numeric) == .orderedDescending
    }

    static func asset(for board: WatchBoard, in assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        assets.first { asset in
            guard asset.name.hasSuffix(".pbz"), asset.name.hasPrefix(assetPrefix) else {
                return false
            }
            let remainder = asset.name.dropFirst(assetPrefix.count).dropLast(".pbz".count)
            // The version follows the board, and a per-slot package adds a suffix after
            // that: `normal_obelix_pvt_v4.36.2_slot0`.
            guard remainder.hasPrefix("\(board.rawValue)_") else { return false }
            return !remainder.hasSuffix("_slot0") && !remainder.hasSuffix("_slot1")
        }
    }

    /// Kept on disk so it can be installed later — on a watch that is not here
    /// yet, or after a first attempt failed.
    public func download(_ release: PebbleOSFirmwareRelease) async throws -> DownloadedFirmware {
        let temporaryURL = try await retry(with: .networkFetch) {
            do {
                return try await downloadFile(from: release.downloadURL, using: session)
            } catch HTTPFileDownloadError.insecureURL {
                throw NotRetryable(PebbleOSFirmwareCatalogError.insecureURL)
            } catch let error as HTTPFileDownloadError {
                throw error.isWorthAnotherAttempt
                    ? PebbleOSFirmwareCatalogError.releasesUnavailable
                    : NotRetryable(PebbleOSFirmwareCatalogError.releasesUnavailable)
            } catch {
                // The file is megabytes, so this is the failure most worth another attempt.
                throw PebbleOSFirmwareCatalogError.releasesUnavailable
            }
        }
        let directory = try Self.downloadDirectory()
        let output = directory
            .appending(path: "pebbleos-\(release.board.rawValue)-\(release.versionTag).pbz")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporaryURL, to: output)
        return DownloadedFirmware(
            versionTag: release.versionTag,
            board: release.board,
            url: output
        )
    }

    // Not the temporary directory: the system empties that whenever it likes, and
    // a package waiting for a watch may wait days.
    private static func downloadDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appending(path: "Firmware", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public enum PebbleOSFirmwareCatalogError: Error, Equatable, Sendable {
    case releasesUnavailable
    case noFirmwareForBoard(WatchBoard)
    case insecureURL
}

struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: URL?
    var assets: [GitHubReleaseAsset]
    /// Nil in older fixtures; GitHub always sends both.
    var prerelease: Bool?
    var draft: Bool?

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets, prerelease, draft
    }
}

struct GitHubReleaseAsset: Decodable {
    var name: String
    var size: Int
    var browserDownloadURL: URL

    private enum CodingKeys: String, CodingKey {
        case name, size
        case browserDownloadURL = "browser_download_url"
    }
}
