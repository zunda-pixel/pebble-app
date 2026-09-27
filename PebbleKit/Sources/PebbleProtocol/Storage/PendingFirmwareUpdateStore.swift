public import Foundation
import MemberwiseInit

public enum FirmwareUpdatePhase: String, Codable, Equatable, Sendable {
    case validated, transferring, installing, awaitingRestart, cancelled, failed

    /// Whether an update in this phase may start again without being asked
    /// for. Only one that was accepted and never sent qualifies: it was staged
    /// deliberately, for a watch that was away. Anything that already ran and
    /// stopped is the reader's call to make again.
    public var mayStartUnattended: Bool {
        self == .validated
    }
}

@MemberwiseInit(.public)
public struct FirmwareUpdateJournal: Codable, Equatable, Sendable {
    public var watchID: WatchID
    public var board: WatchBoard
    /// The slot the package was read for. A dual-slot package holds an image
    /// per slot, so reading it again for no slot could pick the other one.
    public var slot: Int? = nil
    public var previousVersion: String?
    public var targetVersion: String?
    /// The package's name in `FirmwarePackageStore`'s folder, which holds the
    /// only copy of it.
    public var packageFileName: String
    public var packageSHA256: String
    public var phase: FirmwareUpdatePhase = .validated
    public var createdAt: Date = Date()
}

/// Which update each watch has waiting, and where it got to.
///
/// One per watch, because the updates are: a package staged for a watch that
/// is away is no business of the one that is here.
public actor PendingFirmwareUpdateStore {
    private let journalsURL: URL
    private let packageFolderURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        journalsURL = directory.file("firmware-updates.json")
        packageFolderURL = FirmwarePackageStore.folder(in: directory)
    }

    public func journals() throws -> [WatchID: FirmwareUpdateJournal] {
        try PersistentJSON.loadRecovering([WatchID: FirmwareUpdateJournal].self, from: journalsURL) ?? [:]
    }

    public func journal(for watchID: WatchID) throws -> FirmwareUpdateJournal? {
        try journals()[watchID]
    }

    /// Replaces this watch's update. A copy the reader's file was kept as goes
    /// with the update it belonged to; a download stays, for it is the
    /// downloads' to keep.
    public func save(_ journal: FirmwareUpdateJournal) throws {
        var journals = try journals()
        let replaced = journals[journal.watchID]
        journals[journal.watchID] = journal
        try PersistentJSON.save(journals, to: journalsURL)
        if let replaced, replaced.packageFileName != journal.packageFileName {
            removeChosenCopy(replaced.packageFileName, unlessUsedBy: journals)
        }
    }

    /// The package this update is for, read again from its file and checked
    /// against what was accepted. Nil where the file has gone.
    public func package(for journal: FirmwareUpdateJournal) throws -> PBZFirmwarePackage? {
        let url = packageFolderURL.appending(path: journal.packageFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let package = try PBZFirmwareImporter.load(from: url, board: journal.board, targetSlot: journal.slot)
        guard package.sha256 == journal.packageSHA256 else { throw PBZFirmwareError.unsafeManifest }
        return package
    }

    public func updatePhase(_ phase: FirmwareUpdatePhase, watchID: WatchID) throws {
        var journals = try journals()
        guard journals[watchID] != nil else { return }
        journals[watchID]?.phase = phase
        try PersistentJSON.save(journals, to: journalsURL)
    }

    public func clear(watchID: WatchID) {
        guard var journals = try? journals(), let removed = journals.removeValue(forKey: watchID) else {
            return
        }
        try? PersistentJSON.save(journals, to: journalsURL)
        removeChosenCopy(removed.packageFileName, unlessUsedBy: journals)
    }

    private func removeChosenCopy(_ fileName: String, unlessUsedBy journals: [WatchID: FirmwareUpdateJournal]) {
        guard DownloadedFirmware(fileName: fileName) == nil,
              !journals.values.contains(where: { $0.packageFileName == fileName }) else { return }
        try? FileManager.default.removeItem(
            at: packageFolderURL.appending(path: fileName, directoryHint: .notDirectory)
        )
    }
}
