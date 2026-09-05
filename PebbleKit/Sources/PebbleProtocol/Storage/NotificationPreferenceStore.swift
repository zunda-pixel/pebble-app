public import Foundation
import MemberwiseInit

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

public actor NotificationPreferenceStore {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("notification-preferences.json")
    }

    public func preferences() throws -> NotificationDeliveryPreferences {
        try PersistentJSON.loadRecovering(NotificationDeliveryPreferences.self, from: fileURL)
            ?? NotificationDeliveryPreferences()
    }

    public func save(_ preferences: NotificationDeliveryPreferences) throws {
        try PersistentJSON.save(preferences, to: fileURL)
    }
}
