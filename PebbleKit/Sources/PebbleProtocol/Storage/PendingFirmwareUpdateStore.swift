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
    public var deviceID: String
    public var hardwareRevision: String
    public var previousVersion: String?
    public var targetVersion: String?
    public var packageSHA256: String
    public var phase: FirmwareUpdatePhase = .validated
    public var createdAt: Date = Date()
}

public actor PendingFirmwareUpdateStore {
    private var fileURL: URL
    private var journalURL: URL

    public init(fileURL: URL? = nil, journalURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-firmware.json")
        self.journalURL = journalURL ?? applicationSupportURL("pending-firmware-journal.json")
    }

    public func package() throws -> PBZFirmwarePackage? {
        try PersistentJSON.loadRecovering(PBZFirmwarePackage.self, from: fileURL)
    }

    public func journal() throws -> FirmwareUpdateJournal? {
        try PersistentJSON.loadRecovering(FirmwareUpdateJournal.self, from: journalURL)
    }

    public func save(_ package: PBZFirmwarePackage, journal: FirmwareUpdateJournal) throws {
        try PersistentJSON.save(package, to: fileURL)
        try PersistentJSON.save(journal, to: journalURL)
    }

    public func updatePhase(_ phase: FirmwareUpdatePhase) throws {
        guard var value = try journal() else { return }
        value.phase = phase
        try PersistentJSON.save(value, to: journalURL)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: journalURL)
    }
}
