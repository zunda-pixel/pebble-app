public import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct WatchApplicationLibrarySnapshot: Sendable {
    public var applicationID: UUID
    public var applications: [WatchApplication]
    public var packageData: Data?
}

public actor WatchApplicationLibrary {
    private var fileURL: URL
    private var cachedApplications: [WatchApplication]?

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("applications.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func applications() throws -> [WatchApplication] {
        if let cachedApplications {
            return cachedApplications
        }
        if let stored = try PersistentJSON.loadRecovering([WatchApplication].self, from: fileURL) {
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
    private func rebuiltFromPackages() -> [WatchApplication] {
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
    public func upsert(_ application: WatchApplication) throws -> [WatchApplication] {
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
    public func importPackage(from sourceURL: URL) throws -> [WatchApplication] {
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

    public func snapshot(applicationID: UUID) throws -> WatchApplicationLibrarySnapshot {
        let storedPackageURL = packageURL(applicationID: applicationID)
        let packageData = FileManager.default.fileExists(atPath: storedPackageURL.path)
            ? try Data(contentsOf: storedPackageURL)
            : nil
        return WatchApplicationLibrarySnapshot(
            applicationID: applicationID,
            applications: try applications(),
            packageData: packageData
        )
    }

    @discardableResult
    public func restore(_ snapshot: WatchApplicationLibrarySnapshot) throws -> [WatchApplication] {
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
    public func remove(applicationID: UUID) throws -> [WatchApplication] {
        var current = try applications()
        current.removeAll { $0.id == applicationID }
        // The package goes first, and its failure is the caller's. Saving the
        // index first and shrugging off the package left a `.pbw` that
        // `rebuiltFromPackages` would bring back the next time the index was
        // lost — an application the reader was told had been removed.
        let storedPackageURL = packageURL(applicationID: applicationID)
        if FileManager.default.fileExists(atPath: storedPackageURL.path) {
            try FileManager.default.removeItem(at: storedPackageURL)
        }
        try persist(current)
        return current
    }

    @discardableResult
    public func reorder(applicationIDs: [UUID]) throws -> [WatchApplication] {
        let current = try applications()
        let applicationsByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var ordered = applicationIDs.compactMap { applicationsByID[$0] }
        let orderedIDs = Set(applicationIDs)
        ordered.append(contentsOf: current.filter { !orderedIDs.contains($0.id) })
        try persist(ordered)
        return ordered
    }

    public func synchronizedApplicationIDs(watchID: WatchID) throws -> [UUID] {
        try synchronizationStates()[watchID]?.map(\.id) ?? []
    }

    /// The digest of the registration each application was last written to
    /// this watch as. One whose digest still matches is one the watch holds as
    /// it is, and writing it again is not free: the watch reads the insert as
    /// an upgrade, closes the app if it is running and throws away its cached
    /// binary.
    public func writtenApplicationDigests(watchID: WatchID) throws -> [UUID: String] {
        Dictionary(
            (try synchronizationStates()[watchID] ?? []).map { ($0.id, $0.digest) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    /// Keeps the digest already recorded for each application that stays, so
    /// recording what a watch holds without writing to it does not make the
    /// next synchronization write everything again.
    public func setSynchronizedApplicationIDs(_ applicationIDs: [UUID], watchID: WatchID) throws {
        let digests = try writtenApplicationDigests(watchID: watchID)
        try setWrittenApplicationDigests(
            applicationIDs.map { ($0, digests[$0] ?? "") },
            watchID: watchID
        )
    }

    /// In the watch's launcher order, which is the order the file is read in
    /// when a person is diagnosing a fault.
    public func setWrittenApplicationDigests(_ digests: [(UUID, String)], watchID: WatchID) throws {
        var states = try synchronizationStates()
        states[watchID] = digests.map { WrittenApplication(id: $0.0, digest: $0.1) }
        try PersistentJSON.save(states, to: synchronizationStateURL)
    }

    /// Every application stays recorded as given, so one the library lets go
    /// of is still taken off the watch; only the digests go, so each is
    /// written once more.
    public func forgetWrittenApplicationDigests(watchID: WatchID) throws {
        var states = try synchronizationStates()
        guard let written = states[watchID] else { return }
        states[watchID] = written.map { WrittenApplication(id: $0.id, digest: "") }
        try PersistentJSON.save(states, to: synchronizationStateURL)
    }

    /// For every watch: a package imported over the top of one the watch holds
    /// can carry a new binary behind the same registration, and only a fresh
    /// registration makes the watch drop the old one it has cached.
    public func forgetWrittenApplicationDigest(applicationID: UUID) throws {
        var states = try synchronizationStates()
        var changed = false
        for (watchID, written) in states where written.contains(where: { $0.id == applicationID && !$0.digest.isEmpty }) {
            states[watchID] = written.map {
                $0.id == applicationID ? WrittenApplication(id: $0.id, digest: "") : $0
            }
            changed = true
        }
        guard changed else { return }
        try PersistentJSON.save(states, to: synchronizationStateURL)
    }

    public func forgetSynchronizedApplicationIDs(watchID: WatchID) throws {
        var states = try synchronizationStates()
        guard states.removeValue(forKey: watchID) != nil else { return }
        try PersistentJSON.save(states, to: synchronizationStateURL)
    }

    private func persist(_ applications: [WatchApplication]) throws {
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
    ///
    /// The digests came after the plain identifiers, and a file from before
    /// then still names every application its watch was given, which is the
    /// only way to take one off that the library has since let go of. It is
    /// read for its identifiers, each with a digest nothing matches.
    private func synchronizationStates() throws -> [WatchID: [WrittenApplication]] {
        do {
            return try PersistentJSON.load([WatchID: [WrittenApplication]].self, from: synchronizationStateURL) ?? [:]
        } catch where PersistentJSON.isCorrupt(error) {}
        do {
            let identifiers = try PersistentJSON.load([WatchID: [UUID]].self, from: synchronizationStateURL) ?? [:]
            return identifiers.mapValues { $0.map { WrittenApplication(id: $0, digest: "") } }
        } catch where PersistentJSON.isCorrupt(error) {}
        try PersistentJSON.quarantine(synchronizationStateURL)
        return [:]
    }

    private var synchronizationStateURL: URL {
        fileURL.deletingLastPathComponent()
            .appending(path: "application-sync.json", directoryHint: .notDirectory)
    }

}

/// An array of these rather than a `[UUID: String]`, for the reason
/// `TimelinePinStore` gives: that dictionary encodes as alternating strings,
/// which the array of identifiers this file used to hold would read as.
private struct WrittenApplication: Codable, Sendable {
    var id: UUID
    var digest: String
}
