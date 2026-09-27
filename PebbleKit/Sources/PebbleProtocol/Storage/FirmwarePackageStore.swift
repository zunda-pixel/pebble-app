public import Foundation
import MemberwiseInit

/// A PebbleOS package downloaded for one board and kept until a watch takes it.
///
/// Named by its file and nothing else: the package in the firmware folder is
/// the record that it was downloaded, so there is no second copy of the fact
/// to disagree with the first.
@MemberwiseInit(.public)
public struct DownloadedFirmware: Hashable, Sendable {
    public var versionTag: String
    public var board: WatchBoard

    static let prefix = "pebbleos-"
    static let suffix = ".pbz"

    public var fileName: String {
        "\(Self.prefix)\(board.rawValue)-\(versionTag)\(Self.suffix)"
    }

    /// A board's raw value has no hyphen in it, so the first one after the
    /// prefix is where the version starts.
    init?(fileName: String) {
        guard fileName.hasPrefix(Self.prefix), fileName.hasSuffix(Self.suffix) else { return nil }
        let stem = fileName.dropFirst(Self.prefix.count).dropLast(Self.suffix.count)
        guard let separator = stem.firstIndex(of: "-"),
              let board = WatchBoard(rawValue: String(stem[..<separator])) else { return nil }
        let versionTag = String(stem[stem.index(after: separator)...])
        guard !versionTag.isEmpty else { return nil }
        self.init(versionTag: versionTag, board: board)
    }
}

/// The firmware packages on this phone: the ones downloaded from PebbleOS's
/// releases, and copies of the ones the reader chose, kept for an install that
/// has to wait for its watch.
///
/// Inside `StorageDirectory` like every other file here, and referred to by
/// name. An absolute address written down anywhere goes stale on iOS, which
/// moves the app's container on an update or a restore.
public actor FirmwarePackageStore {
    public nonisolated let folderURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        folderURL = Self.folder(in: directory)
    }

    public static func folder(in directory: StorageDirectory) -> URL {
        directory.url.appending(path: "Firmware", directoryHint: .isDirectory)
    }

    public nonisolated func url(for fileName: String) -> URL {
        folderURL.appending(path: fileName, directoryHint: .notDirectory)
    }

    public nonisolated func url(for downloaded: DownloadedFirmware) -> URL {
        url(for: downloaded.fileName)
    }

    /// What has been downloaded, as the folder says.
    public func downloads() -> [DownloadedFirmware] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: folderURL.path(percentEncoded: false)
        )) ?? []
        return names.compactMap(DownloadedFirmware.init(fileName:))
            .sorted { $0.fileName < $1.fileName }
    }

    /// The name a package goes by in this folder: its own, when it is already
    /// here, or that of a copy made now.
    ///
    /// A copy rather than the reader's file itself, because an install staged
    /// for a watch that is away is read again when the watch comes back, and
    /// by then the file the reader chose may be gone or out of reach.
    public func fileName(keeping url: URL) throws -> String {
        if url.deletingLastPathComponent().standardizedFileURL.pathComponents
            == folderURL.standardizedFileURL.pathComponents {
            return url.lastPathComponent
        }
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let name = "chosen-\(UUID().uuidString)\(DownloadedFirmware.suffix)"
        try FileManager.default.copyItem(at: url, to: self.url(for: name))
        return name
    }

    public func remove(fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
    }
}
