public import Foundation
import MemberwiseInit

/// One piece of queued work and the watches that already have it.
///
/// The queue used to be a list of the work alone, and a flush sent each item to
/// every connected watch and kept it if *any* of them refused. With two watches
/// that means the one which took it gets it again on the next flush: shown twice,
/// buzzed twice. Which watch has what belongs to the item.
@MemberwiseInit(.public)
public struct PendingDelivery<Work: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var work: Work
    public var deliveredTo: Set<String> = []

    public func isOwed(by watchID: String) -> Bool {
        !deliveredTo.contains(watchID)
    }
}

/// Reads a queue, accepting one written before the watches were tracked per
/// item — nobody has had those yet, which is what an empty set says. Tried in
/// this order because `loadRecovering` moves a file it cannot decode out of the
/// way, which would take the older shape with it.
private func loadQueue<Work: Codable & Equatable & Sendable>(
    _ work: Work.Type,
    from url: URL
) throws -> [PendingDelivery<Work>] {
    if let stored = try? PersistentJSON.load([PendingDelivery<Work>].self, from: url) {
        return stored
    }
    if let queued = try? PersistentJSON.load([Work].self, from: url) {
        return queued.map { PendingDelivery(work: $0) }
    }
    return try PersistentJSON.loadRecovering([PendingDelivery<Work>].self, from: url) ?? []
}

/// Work queued while no watch is connected, kept so a reconnect can finish it.
public actor PendingNotificationLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-notifications.json")
    }

    public func notifications() throws -> [PendingDelivery<PebbleTimelineNotification>] {
        try loadQueue(PebbleTimelineNotification.self, from: fileURL)
    }

    public func save(_ notifications: [PendingDelivery<PebbleTimelineNotification>]) throws {
        try PersistentJSON.save(notifications, to: fileURL)
    }
}

@MemberwiseInit(.public)
public struct NotificationDeliveryPreferences: Codable, Equatable, Sendable {
    public var mutedApplicationIDs: Set<UUID> = []
    public var quietHoursEnabled: Bool = false
    public var quietHoursStart: Int = 22
    public var quietHoursEnd: Int = 7

    public func permits(applicationID: UUID, at date: Date, calendar: Calendar = .current) -> Bool {
        guard !mutedApplicationIDs.contains(applicationID) else { return false }
        guard quietHoursEnabled else { return true }
        let hour = calendar.component(.hour, from: date)
        if quietHoursStart == quietHoursEnd { return false }
        return quietHoursStart < quietHoursEnd
            ? !(quietHoursStart..<quietHoursEnd).contains(hour)
            : !(hour >= quietHoursStart || hour < quietHoursEnd)
    }
}

public actor NotificationPreferenceLibrary {
    private var fileURL: URL
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("notification-preferences.json")
    }
    public func preferences() throws -> NotificationDeliveryPreferences {
        try PersistentJSON.loadRecovering(NotificationDeliveryPreferences.self, from: fileURL) ?? NotificationDeliveryPreferences()
    }
    public func save(_ preferences: NotificationDeliveryPreferences) throws {
        try PersistentJSON.save(preferences, to: fileURL)
    }
}

public enum PendingTimelineOperation: Codable, Equatable, Sendable {
    case upsert(PebbleTimelinePin)
    case delete(UUID)
}

public actor PendingTimelineOperationLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-timeline.json")
    }

    public func operations() throws -> [PendingTimelineOperation] {
        try PersistentJSON.loadRecovering([PendingTimelineOperation].self, from: fileURL) ?? []
    }

    public func save(_ operations: [PendingTimelineOperation]) throws {
        try PersistentJSON.save(operations, to: fileURL)
    }
}

@MemberwiseInit(.public)
public struct StoredAppMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var applicationID: UUID
    public var tuples: [AppMessageTuple]
    public var createdAt: Date = Date()
}

public actor PendingAppMessageLibrary {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-appmessages.json")
    }

    /// A plain list: an app message is addressed to an application and sent to
    /// one watch, so there is no per-watch delivery to remember.
    public func messages() throws -> [StoredAppMessage] {
        try PersistentJSON.loadRecovering([StoredAppMessage].self, from: fileURL) ?? []
    }

    public func save(_ messages: [StoredAppMessage]) throws {
        try PersistentJSON.save(messages, to: fileURL)
    }
}

public actor PendingFirmwareUpdateLibrary {
    private var fileURL: URL
    private var journalURL: URL
    public func package() throws -> PBZFirmwarePackage? { try PersistentJSON.loadRecovering(PBZFirmwarePackage.self, from: fileURL) }
    public init(fileURL: URL? = nil, journalURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("pending-firmware.json")
        self.journalURL = journalURL ?? applicationSupportURL("pending-firmware-journal.json")
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
