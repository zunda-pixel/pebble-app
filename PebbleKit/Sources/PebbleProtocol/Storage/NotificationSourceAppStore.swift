public import Foundation

public actor NotificationSourceAppStore {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("notification-source-apps.json")
    }

    public func apps() throws -> [NotificationSourceApp] {
        try PersistentJSON.loadRecovering([NotificationSourceApp].self, from: fileURL) ?? []
    }

    public func save(_ apps: [NotificationSourceApp]) throws {
        try PersistentJSON.save(
            apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            to: fileURL
        )
    }

    public func update(_ app: NotificationSourceApp) throws -> [NotificationSourceApp] {
        var apps = try apps()
        if let index = apps.firstIndex(where: { $0.bundleID == app.bundleID }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
        try save(apps)
        return try self.apps()
    }

    public func merge(_ app: NotificationSourceApp) throws -> [NotificationSourceApp] {
        var apps = try apps()
        if let index = apps.firstIndex(where: { $0.bundleID == app.bundleID }) {
            if app.stateUpdated > apps[index].stateUpdated {
                var merged = app
                // The watch's record says nothing about the icon, the colours or
                // the buzz, which are the phone's to choose.
                merged.icon = apps[index].icon
                merged.backgroundColor = apps[index].backgroundColor
                merged.foregroundColor = apps[index].foregroundColor
                merged.vibePattern = apps[index].vibePattern
                merged.filterRules = apps[index].filterRules
                apps[index] = merged
            }
        } else {
            apps.append(app)
        }
        try save(apps)
        return try self.apps()
    }
}
