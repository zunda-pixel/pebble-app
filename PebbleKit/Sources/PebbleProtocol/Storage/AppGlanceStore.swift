public import Foundation

public actor AppGlanceStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("app-glances.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func glances() throws -> [AppGlance] {
        try PersistentJSON.loadRecovering([AppGlance].self, from: fileURL) ?? []
    }

    public func save(_ glances: [AppGlance]) throws {
        try PersistentJSON.save(glances, to: fileURL)
    }

    public func update(_ glance: AppGlance) throws -> [AppGlance] {
        var glances = try self.glances()
        glances.removeAll { $0.applicationID == glance.applicationID }
        if !glance.slices.isEmpty {
            glances.append(glance)
        }
        try save(glances)
        return glances
    }
}
