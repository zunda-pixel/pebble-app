public import Foundation
import HTTPTypes
import HTTPTypesFoundation
import MemberwiseInit

/// A firmware package that has been fetched and is waiting on disk.
@MemberwiseInit(.public)
public struct DownloadedFirmware: Codable, Equatable, Sendable {
    public var versionTag: String
    public var board: PebbleWatchBoard
    public var url: URL
}

/// One firmware package published for a board.
@MemberwiseInit(.public)
public struct PebbleOSFirmwareRelease: Equatable, Sendable {
    public var versionTag: String
    public var board: PebbleWatchBoard
    public var downloadURL: URL
    public var sizeInBytes: Int
    public var releaseNotesURL: URL?
}

/// Finds firmware on the PebbleOS releases page.
///
/// PebbleOS publishes a package per board with every release, and the download
/// needs no credentials — unlike the update services the official app uses,
/// which are the reason firmware cannot be fetched from there.
public struct PebbleOSFirmwareCatalog: Sendable {
    /// Assets are named `normal_<board>_<version>.pbz`. A dual-slot board also
    /// publishes `_slot0`/`_slot1` variants holding one slot each; the plain
    /// one holds both, so it suits any watch.
    static let assetPrefix = "normal_"

    private let releasesURL: URL
    private let session: URLSession

    public init(
        releasesURL: URL = URL(string: "https://api.github.com/repos/coredevices/PebbleOS/releases/latest")!,
        session: URLSession? = nil
    ) {
        self.releasesURL = releasesURL
        if let session {
            self.session = session
        } else {
            // A firmware package is megabytes; the default request timeout is
            // not enough on a slow link.
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    /// The newest firmware published for a board.
    public func latestRelease(for board: PebbleWatchBoard) async throws -> PebbleOSFirmwareRelease {
        let request = HTTPRequest(
            method: .get,
            url: releasesURL,
            headerFields: [.accept: "application/vnd.github+json"]
        )
        let (data, response) = try await session.data(for: request)
        guard response.status == .ok else {
            throw PebbleOSFirmwareCatalogError.releasesUnavailable
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = Self.asset(for: board, in: release.assets) else {
            throw PebbleOSFirmwareCatalogError.noFirmwareForBoard(board)
        }
        return PebbleOSFirmwareRelease(
            versionTag: release.tagName,
            board: board,
            downloadURL: asset.browserDownloadURL,
            sizeInBytes: asset.size,
            releaseNotesURL: release.htmlURL
        )
    }

    /// Picks the package that covers every slot of a board.
    static func asset(for board: PebbleWatchBoard, in assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        assets.first { asset in
            guard asset.name.hasSuffix(".pbz"), asset.name.hasPrefix(assetPrefix) else {
                return false
            }
            let remainder = asset.name.dropFirst(assetPrefix.count).dropLast(".pbz".count)
            // The version follows the board, and a per-slot package adds a
            // suffix after that: `normal_obelix_pvt_v4.36.2_slot0`.
            guard remainder.hasPrefix("\(board.rawValue)_") else { return false }
            return !remainder.hasSuffix("_slot0") && !remainder.hasSuffix("_slot1")
        }
    }

    /// Downloads a package to a file the firmware importer can read.
    /// Fetches a release and keeps it, so it can be installed later — on a
    /// watch that is not here yet, or after a first attempt stopped.
    public func download(_ release: PebbleOSFirmwareRelease) async throws -> DownloadedFirmware {
        let temporaryURL: URL
        do {
            temporaryURL = try await downloadFile(from: release.downloadURL, using: session)
        } catch HTTPFileDownloadError.insecureURL {
            throw PebbleOSFirmwareCatalogError.insecureURL
        } catch {
            throw PebbleOSFirmwareCatalogError.releasesUnavailable
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

    /// Downloads live in Application Support rather than the temporary
    /// directory: the system empties that one whenever it likes, and a package
    /// waiting for a watch to turn up may wait a while.
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
    case noFirmwareForBoard(PebbleWatchBoard)
    case insecureURL
}

struct GitHubRelease: Decodable {
    var tagName: String
    var htmlURL: URL?
    var assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
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
