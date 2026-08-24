public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct PebbleApplicationLibrarySnapshot: Sendable {
    public var applicationID: UUID
    public var applications: [PebbleApplication]
    public var packageData: Data?
}

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
        let snapshot = try snapshot(applicationID: application.id)
        let packageURL = packageURL(applicationID: application.id)
        try FileManager.default.createDirectory(
            at: packageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: sourceURL).write(to: packageURL, options: .atomic)
        do {
            return try upsert(application)
        } catch {
            try? restore(snapshot)
            throw error
        }
    }

    public func snapshot(applicationID: UUID) throws -> PebbleApplicationLibrarySnapshot {
        let storedPackageURL = packageURL(applicationID: applicationID)
        let packageData = FileManager.default.fileExists(atPath: storedPackageURL.path)
            ? try Data(contentsOf: storedPackageURL)
            : nil
        return PebbleApplicationLibrarySnapshot(
            applicationID: applicationID,
            applications: try applications(),
            packageData: packageData
        )
    }

    @discardableResult
    public func restore(_ snapshot: PebbleApplicationLibrarySnapshot) throws -> [PebbleApplication] {
        let storedPackageURL = packageURL(applicationID: snapshot.applicationID)
        if let packageData = snapshot.packageData {
            try FileManager.default.createDirectory(
                at: storedPackageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try packageData.write(to: storedPackageURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: storedPackageURL.path) {
            try FileManager.default.removeItem(at: storedPackageURL)
        }
        try persist(snapshot.applications)
        return snapshot.applications
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

    public func synchronizedApplicationIDs(deviceID: String) throws -> [UUID] {
        try synchronizationStates()[deviceID] ?? []
    }

    public func setSynchronizedApplicationIDs(_ applicationIDs: [UUID], deviceID: String) throws {
        var states = try synchronizationStates()
        states[deviceID] = applicationIDs
        let url = synchronizationStateURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(states).write(to: url, options: .atomic)
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

    private func synchronizationStates() throws -> [String: [UUID]] {
        guard FileManager.default.fileExists(atPath: synchronizationStateURL.path) else {
            return [:]
        }
        return try JSONDecoder().decode(
            [String: [UUID]].self,
            from: Data(contentsOf: synchronizationStateURL)
        )
    }

    private var synchronizationStateURL: URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "application-sync.json", directoryHint: .notDirectory)
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
