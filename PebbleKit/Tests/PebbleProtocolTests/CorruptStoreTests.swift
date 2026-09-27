import Foundation
import Testing
import ZIPFoundation
@testable import PebbleProtocol

/// What each store does with a file it cannot read.
///
/// Every one of these used to hand the `DecodingError` straight back, and
/// because nothing cached the failure the next read did it again: one bad byte
/// in `watches.json` meant no watch could ever be saved again, with no way out
/// but deleting the file by hand.
@Suite
@MainActor
struct CorruptStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    /// Half a JSON array: valid UTF-8, and `JSONDecoder` refuses it.
    private func writeTruncatedJSON(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"[{"id":"mock-flint","name":"Pebble 2 Duo""#.utf8).write(to: url)
    }

    private func quarantinedFiles(besides url: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(url.lastPathComponent).corrupt-") }
    }

    @Test func aTruncatedWatchListIsMovedAsideAndReadsEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "watches.json")
        try writeTruncatedJSON(to: fileURL)

        let store = SavedWatchStore(fileURL: fileURL)
        #expect(try await store.allWatches().isEmpty)
        #expect(try quarantinedFiles(besides: fileURL).count == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        // The point of moving it aside: a watch can be saved again afterwards.
        let saved = try await store.record(
            ConnectedWatch(
            id: WatchID("mock-flint"),
            name: "Pebble 2 Duo",
            model: .pebble2Duo,
            batteryLevel: 84,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0",
                serialNumber: nil,
                hardwarePlatform: 15
            )
        )
        )
        #expect(saved.count == 1)
        #expect(try await SavedWatchStore(fileURL: fileURL).allWatches().count == 1)
    }

    @Test func aTruncatedPinFileIsMovedAsideAndReadsEmpty() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "timeline.json")
        try writeTruncatedJSON(to: fileURL)

        let store = TimelinePinStore(fileURL: fileURL)
        #expect(try await store.pins().isEmpty)
        #expect(try quarantinedFiles(besides: fileURL).count == 1)

        let pin = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_788_393_600),
            title: "Stand up",
            subtitle: nil,
            body: nil
        )
        try await store.save([pin])
        #expect(try await store.pins() == [pin])
    }

    /// The packages are the record; `applications.json` is only the order.
    @Test func aCorruptApplicationIndexIsRebuiltFromThePackagesOnDisk() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "applications.json")
        let packages = directory.appending(path: "Packages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)

        var identifiers: [UUID] = []
        for index in 0..<3 {
            let applicationID = UUID()
            identifiers.append(applicationID)
            let source = try makeApplicationPackage(
                in: directory,
                applicationID: applicationID,
                name: "App \(index)"
            )
            try FileManager.default.moveItem(
                at: source,
                to: packages.appending(path: "\(applicationID.uuidString).pbw")
            )
        }
        try writeTruncatedJSON(to: fileURL)

        let library = WatchApplicationLibrary(fileURL: fileURL)
        let rebuilt = try await library.applications()

        #expect(Set(rebuilt.map(\.id)) == Set(identifiers))
        #expect(try quarantinedFiles(besides: fileURL).count == 1)
        // Rebuilt and written back, so the next launch does not scan again.
        #expect(try await WatchApplicationLibrary(fileURL: fileURL).applications().count == 3)
    }

    @Test func aPackageThatCannotBeDeletedFailsTheRemovalAndKeepsTheApplication() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "applications.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let applicationID = UUID()
        let source = try makeApplicationPackage(in: directory, applicationID: applicationID, name: "App")
        let library = WatchApplicationLibrary(fileURL: fileURL)
        try await library.importPackage(from: source)

        let packages = directory.appending(path: "Packages", directoryHint: .isDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: packages.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: packages.path)
        }

        await #expect(throws: (any Error).self) {
            try await library.remove(applicationID: applicationID)
        }
        #expect(try await library.applications().map(\.id) == [applicationID])
        #expect(try await WatchApplicationLibrary(fileURL: fileURL).applications().map(\.id) == [applicationID])
    }

    /// One unreadable package must not cost the reader the other two: the whole
    /// point of the rebuild is that a single bad file is survivable.
    @Test func anUnreadablePackageIsSkippedRatherThanFailingTheRebuild() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "applications.json")
        let packages = directory.appending(path: "Packages", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)

        for index in 0..<2 {
            let applicationID = UUID()
            let source = try makeApplicationPackage(
                in: directory,
                applicationID: applicationID,
                name: "App \(index)"
            )
            try FileManager.default.moveItem(
                at: source,
                to: packages.appending(path: "\(applicationID.uuidString).pbw")
            )
        }
        try Data("not a zip archive".utf8)
            .write(to: packages.appending(path: "\(UUID().uuidString).pbw"))
        try writeTruncatedJSON(to: fileURL)

        #expect(try await WatchApplicationLibrary(fileURL: fileURL).applications().count == 2)
    }

    @Test func aCorruptSynchronizationRecordReadsAsNothingSynchronized() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "applications.json")
        let syncURL = directory.appending(path: "application-sync.json")
        try writeTruncatedJSON(to: syncURL)

        let library = WatchApplicationLibrary(fileURL: fileURL)
        #expect(try await library.synchronizedApplicationIDs(watchID: WatchID("mock-flint")).isEmpty)

        let applicationID = UUID()
        try await library.setSynchronizedApplicationIDs([applicationID], watchID: WatchID("mock-flint"))
        #expect(try await library.synchronizedApplicationIDs(watchID: WatchID("mock-flint")) == [applicationID])
    }

    /// The record of what each watch was given gained a digest beside every
    /// identifier. A file written before that still names every pin its watch
    /// holds, and that record is the only way to find one the app has since
    /// forgotten — so it is read rather than moved aside, unlike the files
    /// above.
    @Test func aWrittenPinFileFromBeforeTheDigestKeepsItsIdentifiers() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writtenURL = directory.appending(path: "timeline-written.json")
        let pinID = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"mock-flint":["\#(pinID.uuidString)"]}"#.utf8).write(to: writtenURL)

        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))

        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")) == [pinID])
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))
        #expect(try quarantinedFiles(besides: writtenURL).isEmpty)
        // No digest can match, so the pin is written once more and left alone.
        #expect(try await store.writtenPinDigests(watchID: WatchID("mock-flint")) == [pinID: ""])
    }

    /// Neither shape: the same recovery as the files above, because a record
    /// that cannot be read would fail every read from then on.
    @Test func aWrittenPinFileThatIsNeitherShapeIsMovedAside() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writtenURL = directory.appending(path: "timeline-written.json")
        try writeTruncatedJSON(to: writtenURL)

        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))

        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: writtenURL.path))
        #expect(try quarantinedFiles(besides: writtenURL).count == 1)

        // And it can be written again.
        let pinID = UUID()
        try await store.setWrittenPinDigests([pinID: "digest"], watchID: WatchID("mock-flint"))
        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")) == [pinID])
    }

    @Test func aWrittenPinFileThatCannotBeReadJustNowIsLeftWhereItIs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writtenURL = directory.appending(path: "timeline-written.json")
        let pinID = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"mock-flint":[{"id":"\#(pinID.uuidString)","digest":"d"}]}"#.utf8).write(to: writtenURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: writtenURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: writtenURL.path)
        }

        let store = TimelinePinStore(fileURL: directory.appending(path: "timeline.json"))

        await #expect(throws: (any Error).self) {
            try await store.writtenPinIDs(watchID: WatchID("mock-flint"))
        }
        #expect(FileManager.default.fileExists(atPath: writtenURL.path))
        #expect(try quarantinedFiles(besides: writtenURL).isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: writtenURL.path)
        #expect(try await store.writtenPinIDs(watchID: WatchID("mock-flint")) == [pinID])
    }

    @Test func aFileThatCannotBeReadJustNowIsNotMovedAside() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "watches.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        }

        #expect(throws: (any Error).self) {
            try PersistentJSON.loadRecovering([String].self, from: fileURL)
        }
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try quarantinedFiles(besides: fileURL).isEmpty)
    }

    /// A `.pbw` holding one application built for the Pebble Time 2.
    private func makeApplicationPackage(
        in directory: URL,
        applicationID: UUID,
        name: String
    ) throws -> URL {
        let url = directory.appending(path: "\(UUID().uuidString).pbw")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }

        try add("appinfo.json", Data("""
        {
          "uuid": "\(applicationID.uuidString.lowercased())",
          "shortName": "\(name)",
          "longName": "\(name)",
          "companyName": "Pebble",
          "versionLabel": "1.0",
          "targetPlatforms": ["emery"],
          "watchapp": { "watchface": false }
        }
        """.utf8))

        // The executable carries the identifier the importer checks the package
        // against, so its header has to name this application.
        var executable = [UInt8](repeating: 0, count: PBWBinaryHeaderDecoder.size)
        executable.replaceSubrange(0..<8, with: [0x50, 0x42, 0x4C, 0x41, 0x50, 0x50, 0, 0])
        executable.replaceSubrange(8..<14, with: [1, 0, 4, 2, 3, 7])
        let identifier = applicationID.uuid
        executable.replaceSubrange(104..<120, with: [
            identifier.0, identifier.1, identifier.2, identifier.3,
            identifier.4, identifier.5, identifier.6, identifier.7,
            identifier.8, identifier.9, identifier.10, identifier.11,
            identifier.12, identifier.13, identifier.14, identifier.15,
        ])
        try add("emery/pebble-app.bin", Data(executable))
        try add("emery/manifest.json", Data("""
        {
          "application": { "name": "pebble-app.bin", "size": \(executable.count) }
        }
        """.utf8))
        return url
    }
}
