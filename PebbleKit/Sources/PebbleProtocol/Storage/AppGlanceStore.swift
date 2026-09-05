public import Foundation

public actor AppGlanceStore {
    private var fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? applicationSupportURL("app-glances.json")
    }

    public func glances() throws -> [PebbleAppGlance] {
        try PersistentJSON.loadRecovering([PebbleAppGlance].self, from: fileURL) ?? []
    }

    public func save(_ glances: [PebbleAppGlance]) throws {
        try PersistentJSON.save(glances, to: fileURL)
    }

    public func update(_ glance: PebbleAppGlance) throws -> [PebbleAppGlance] {
        var glances = try self.glances()
        glances.removeAll { $0.applicationID == glance.applicationID }
        if !glance.slices.isEmpty {
            glances.append(glance)
        }
        try save(glances)
        return glances
    }
}
