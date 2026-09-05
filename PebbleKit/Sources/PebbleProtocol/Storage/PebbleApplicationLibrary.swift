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
        if let stored = try PersistentJSON.loadRecovering([PebbleApplication].self, from: fileURL) {
            cachedApplications = stored
            return stored
        }
        // Either nothing has ever been saved or the file has just been
        // quarantined. Both read the same way from here, and the packages under
        // `Packages/` are the real record either way.
        let rebuilt = rebuiltFromPackages()
        if !rebuilt.isEmpty {
            try persist(rebuilt)
        } else {
            cachedApplications = []
        }
        return rebuilt
    }

    /// The library read back off the `.pbw` files still on disk.
    ///
    /// A package is what an application was installed from, so nothing about it
    /// is lost by reading it again — except the order the reader put them in,
    /// which lives only in `applications.json`. Newest file last, which is the
    /// order they were imported in and so usually the order that was lost.
    ///
    /// A package that cannot be read is skipped rather than failing the
    /// rebuild: one unreadable file must not cost the reader the rest of their
    /// library, which is exactly the trap the corrupt index was.
    private func rebuiltFromPackages() -> [PebbleApplication] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: packagesDirectoryURL,
            includingPropertiesForKeys: [.creationDateKey]
        )
        let packages = (contents ?? [])
            .filter { $0.pathExtension == "pbw" }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left == right ? lhs.lastPathComponent < rhs.lastPathComponent : left < right
            }
        return packages.compactMap { try? PBWPackageImporter.application(from: $0) }
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
            // The snapshot is the only way back to a consistent library; if
            // even that fails the original error is still the useful one.
            do {
                try restore(snapshot)
            } catch let restoreError {
                assertionFailure("Could not restore the application library: \(restoreError)")
            }
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

    public func companionJavaScript(applicationID: UUID) throws -> String? {
        guard let url = storedPackageURL(applicationID: applicationID) else { return nil }
        return try PBWPackageImporter.companionJavaScript(from: url)
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
        try PersistentJSON.save(states, to: synchronizationStateURL)
    }

    private func persist(_ applications: [PebbleApplication]) throws {
        try PersistentJSON.save(applications, to: fileURL)
        cachedApplications = applications
    }

    private var packagesDirectoryURL: URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "Packages", directoryHint: .isDirectory)
    }

    private func packageURL(applicationID: UUID) -> URL {
        packagesDirectoryURL
            .appending(path: "\(applicationID.uuidString).pbw", directoryHint: .notDirectory)
    }

    /// Which applications each watch was last given. Nothing rebuilds this —
    /// only the watch knows — so a file that cannot be read is moved aside and
    /// every watch is synchronized again, which is work rather than a fault.
    private func synchronizationStates() throws -> [String: [UUID]] {
        try PersistentJSON.loadRecovering([String: [UUID]].self, from: synchronizationStateURL) ?? [:]
    }

    private var synchronizationStateURL: URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "application-sync.json", directoryHint: .notDirectory)
    }

    private static var defaultFileURL: URL {
        applicationSupportURL("applications.json")
    }
}
