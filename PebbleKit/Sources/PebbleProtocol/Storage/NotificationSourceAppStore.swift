public import Foundation

public actor NotificationSourceAppStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("notification-source-apps.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func apps() throws -> [NotificationSourceApp] {
        try PersistentJSON.loadRecovering([NotificationSourceApp].self, from: fileURL) ?? []
    }

    public func save(_ apps: [NotificationSourceApp]) throws {
        try PersistentJSON.save(Self.sorted(apps), to: fileURL)
    }

    public func update(_ app: NotificationSourceApp) throws -> [NotificationSourceApp] {
        let stored = try apps()
        var apps = stored
        if let index = apps.firstIndex(where: { $0.bundleID == app.bundleID }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
        return try save(apps, replacing: stored)
    }

    public func merge(_ app: NotificationSourceApp) throws -> [NotificationSourceApp] {
        let stored = try apps()
        var apps = stored
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
        return try save(apps, replacing: stored)
    }

    private func save(
        _ apps: [NotificationSourceApp],
        replacing stored: [NotificationSourceApp]
    ) throws -> [NotificationSourceApp] {
        let sorted = Self.sorted(apps)
        if sorted != stored {
            try PersistentJSON.save(sorted, to: fileURL)
        }
        return sorted
    }

    private static func sorted(_ apps: [NotificationSourceApp]) -> [NotificationSourceApp] {
        apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
