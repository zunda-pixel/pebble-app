public import Foundation

public actor PebbleApplicationLibrary {
    private var fileURL: URL
    private var cachedApplications: [PebbleApplication]?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    public func applications() throws -> [PebbleApplication] {
        if let cachedApplications {
            return cachedApplications
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedApplications = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let applications = try JSONDecoder().decode([PebbleApplication].self, from: data)
        cachedApplications = applications
        return applications
    }

    @discardableResult
    public func upsert(_ application: PebbleApplication) throws -> [PebbleApplication] {
        var current = try applications()
        if let index = current.firstIndex(where: { $0.id == application.id }) {
            current[index] = application
        } else {
            current.append(application)
        }
        try persist(current)
        return current
    }

    @discardableResult
    public func importPackage(from sourceURL: URL) throws -> [PebbleApplication] {
        let application = try PBWPackageImporter.application(from: sourceURL)
        let packageURL = packageURL(applicationID: application.id)
        try FileManager.default.createDirectory(
            at: packageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(to: packageURL, options: .atomic)
        do {
            return try upsert(application)
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    public func storedPackageURL(applicationID: UUID) -> URL? {
        let url = packageURL(applicationID: applicationID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func remove(applicationID: UUID) throws -> [PebbleApplication] {
        var current = try applications()
        current.removeAll { $0.id == applicationID }
        try persist(current)
        let storedPackageURL = packageURL(applicationID: applicationID)
        if FileManager.default.fileExists(atPath: storedPackageURL.path) {
            try? FileManager.default.removeItem(at: storedPackageURL)
        }
        return current
    }

    @discardableResult
    public func reorder(applicationIDs: [UUID]) throws -> [PebbleApplication] {
        let current = try applications()
        let applicationsByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var ordered = applicationIDs.compactMap { applicationsByID[$0] }
        let orderedIDs = Set(applicationIDs)
        ordered.append(contentsOf: current.filter { !orderedIDs.contains($0.id) })
        try persist(ordered)
        return ordered
    }

    private func persist(_ applications: [PebbleApplication]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(applications).write(to: fileURL, options: .atomic)
        cachedApplications = applications
    }

    private func packageURL(applicationID: UUID) -> URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "Packages", directoryHint: .isDirectory)
            .appending(path: "\(applicationID.uuidString).pbw", directoryHint: .notDirectory)
    }

    private static var defaultFileURL: URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.temporaryDirectory
        return baseURL
            .appending(path: "Pebble", directoryHint: .isDirectory)
            .appending(path: "applications.json", directoryHint: .notDirectory)
    }
}
