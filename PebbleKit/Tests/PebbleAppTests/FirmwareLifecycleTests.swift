import PebbleProtocol
@testable import PebbleTransport
import Foundation
import SwiftUI
import Testing
import ZIPFoundation
@testable import PebbleApp

/// Choosing and starting a firmware update.
///
/// Serialized because these tests share one on-disk staging library: it is a
/// fixed location inside the app's own storage, not something a test can point
/// somewhere else, so two of them running at once would each read the other's
/// staged update.
@Suite(.serialized)
@MainActor
struct FirmwareLifecycleTests {
    @Test
    func firmwareChosenWhileDisconnectedWaitsForTheWatch() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        // A watch running recovery firmware stays connected for only a few
        // seconds, so the file has to be accepted while it is away.
        try await watchStore.record(ConnectedWatch(
            id: WatchID("recovery-watch"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        ))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: watchStore
        )
        await model.loadSavedWatches()
        let firmwareURL = try makeFirmwareArchive(in: directory)

        await model.installFirmware(from: firmwareURL, watchID: WatchID("recovery-watch"))

        let journal = try #require(model.firmware.journal)
        #expect(journal.watchID == WatchID("recovery-watch"))
        #expect(client.installedFirmwarePackages.isEmpty)

        await model.discardPendingFirmwareUpdate()
    }

    @Test
    func aSecondTransferIsRefusedWhileOneIsAlreadyRunning() async throws {
        // Two updates can be asked for at once: a staged one starts itself the
        // moment the watch reconnects, and the reader can tap Install in the
        // same breath. The second used to take over the task and the transfer
        // flags, leaving the first waiting on a reply nobody held — and with it
        // the keepalive suppressed for the rest of the link.
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
        let connection = WatchConnection(client: client, watch: watch)
        let package = makeFirmwarePackage()
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: watch.id,
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: nil,
            packageSHA256: package.sha256
        ))

        let running = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        model.firmwareUpdateTask = running

        try await model.performFirmwareUpdate(package, on: connection)

        #expect(client.installedFirmwarePackages.isEmpty)
        // The transfer that is already running still owns the slot, and no
        // progress display was hijacked from it.
        #expect(model.firmwareUpdateTask != nil)
        #expect(model.firmwareTransferProgress(on: watch.id) == nil)
        #expect(model.firmware.feedback == .failure("This firmware is already being transferred."))

        running.cancel()
        await model.discardPendingFirmwareUpdate()
    }

    @Test
    func aFinishedInstallTakesTheDownloadedPackageWithIt() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
        let package = makeFirmwarePackage(versionTag: "v4.36.2")
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: watch.id,
            board: .obelixPVT,
            previousVersion: "v4.9.142",
            targetVersion: "v4.36.2",
            packageSHA256: package.sha256
        ))
        let onDisk = directory.appending(path: "pebbleos-obelix_pvt-v4.36.2.pbz")
        try Data([1]).write(to: onDisk)
        model.firmware.downloaded = DownloadedFirmware(
            versionTag: "v4.36.2",
            board: .obelixPVT,
            url: onDisk
        )

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch))

        // Otherwise the firmware screen goes on offering an install of what the
        // watch is at that moment restarting into.
        #expect(model.firmware.downloaded == nil)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path(percentEncoded: false)))
    }

    @Test
    func aDownloadForAnotherVersionSurvivesAnInstall() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
        let package = makeFirmwarePackage(versionTag: "v4.36.2")
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: watch.id,
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: "v4.36.2",
            packageSHA256: package.sha256
        ))
        let onDisk = directory.appending(path: "pebbleos-obelix_pvt-v4.37.0.pbz")
        try Data([1]).write(to: onDisk)
        // A watch installing firmware from a file is no reason to throw away a
        // download meant for another watch, or for the next release.
        model.firmware.downloaded = DownloadedFirmware(
            versionTag: "v4.37.0",
            board: .obelixPVT,
            url: onDisk
        )

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch))

        #expect(model.firmware.downloaded?.versionTag == "v4.37.0")
        #expect(FileManager.default.fileExists(atPath: onDisk.path(percentEncoded: false)))
    }

    @Test
    func aWatchBackFromItsUpdateIsNoLongerWaitingForARestart() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
        let package = makeFirmwarePackage(versionTag: "v4.36.2")
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: watch.id,
            board: .obelixPVT,
            previousVersion: "v4.9.142",
            targetVersion: "v4.36.2",
            packageSHA256: package.sha256
        ))

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch))
        #expect(model.firmware.journal?.phase == .awaitingRestart)

        await model.recordConnectedWatch(watch)

        // The journal is already gone from disk, so nothing but the watch
        // itself can end this: left alone the firmware screen kept offering
        // Stop and Try Again for an update that had finished, and the watch's
        // own row went on saying an update was waiting.
        #expect(model.firmware.journal == nil)
        #expect(model.firmware.feedback == nil)
    }

    @Test
    func choosingAnotherPackageDuringATransferLeavesTheStagedOneAlone() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let package = makeFirmwarePackage(versionTag: "v4.36.2")
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: WatchID("watch-1"),
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: "v4.36.2",
            packageSHA256: package.sha256
        ))
        let running = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        model.firmwareUpdateTask = running

        await model.installFirmware(from: try makeFirmwareArchive(in: directory), watchID: WatchID("watch-1"))

        #expect(try await model.pendingFirmwareUpdateStore.journal()?.packageSHA256 == package.sha256)
        #expect(model.firmware.feedback == .failure("This firmware is already being transferred."))

        running.cancel()
        model.firmwareUpdateTask = nil
        await model.discardPendingFirmwareUpdate()
    }

    @Test
    func aCancelledTransferFinishingLateLeavesTheNextOneRunning() async throws {
        let client = SuspendingWatchClient()
        // The second outlasts the first by far more than the cancel and the
        // restart take, so it is still running when the first one ends.
        client.firmwareTransferTimes = [.milliseconds(300), .seconds(1)]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let watch = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
        let connection = WatchConnection(client: client, watch: watch)
        let package = makeFirmwarePackage(versionTag: "v4.36.2")
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: watch.id,
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: "v4.36.2",
            packageSHA256: package.sha256
        ))

        let first = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }
        await model.cancelFirmwareUpdate()
        let second = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(model.firmwareUpdateTask != nil)
        #expect(connection.transferProgress(for: .firmware) != nil)

        try await second.value
        #expect(model.firmwareUpdateTask == nil)
        await model.discardPendingFirmwareUpdate()
    }

    @Test
    func anotherBoardsDownloadIsNotInstalledOnThisWatch() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let board = try #require(model.board(for: discovered.id))
        let otherBoard = try #require(WatchBoard.allCases.first { $0 != board })
        model.firmware.downloaded = DownloadedFirmware(
            versionTag: "v4.37.0",
            board: otherBoard,
            url: try makeFirmwareArchive(in: directory)
        )

        await model.installDownloadedFirmware(watchID: discovered.id)

        #expect(model.firmware.journal == nil)
        #expect(client.installedFirmwarePackages.isEmpty)
        #expect(model.firmware.feedback?.isFailure == true)
    }

    @Test
    func confirmingARecoveryUpdateForAnAbsentWatchSaysSo() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let package = makeFirmwarePackage()
        try await model.pendingFirmwareUpdateStore.save(package, journal: FirmwareUpdateJournal(
            watchID: WatchID("away"),
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: nil,
            packageSHA256: package.sha256
        ))
        model.firmware.requiresConfirmation = true

        await model.confirmRecoveryFirmwareUpdate()

        #expect(model.firmware.feedback?.isFailure == true)
        #expect(model.firmware.requiresConfirmation)
        #expect(client.installedFirmwarePackages.isEmpty)
        await model.discardPendingFirmwareUpdate()
    }

    private func makeFirmwarePackage(versionTag: String? = nil) -> PBZFirmwarePackage {
        let firmware = Data([4, 3, 2, 1])
        return PBZFirmwarePackage(
            manifest: PBZFirmwareManifest(
                manifestVersion: 1,
                firmware: PBZFirmwareBlob(
                    name: "firmware.bin",
                    type: "normal",
                    boardName: WatchBoard.obelixPVT.rawValue,
                    size: firmware.count,
                    crc: PebbleCRC32.calculate([UInt8](firmware)),
                    versionTag: versionTag,
                    slot: nil
                ),
                resources: nil
            ),
            firmware: firmware,
            resources: nil
        )
    }

    private func makeFirmwareArchive(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "firmware.pbz")
        let archive = try Archive(url: url, accessMode: .create)
        let firmware = Data([4, 3, 2, 1])
        let manifest = Data("""
        {
          "manifestVersion": 1,
          "firmware": {
            "name": "firmware.bin",
            "type": "normal",
            "hwrev": "\(WatchBoard.obelixPVT.rawValue)",
            "size": \(firmware.count),
            "crc": \(PebbleCRC32.calculate([UInt8](firmware)))
          }
        }
        """.utf8)
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            provider: { position, size in
                manifest.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        try archive.addEntry(
            with: "firmware.bin",
            type: .file,
            uncompressedSize: Int64(firmware.count),
            provider: { position, size in
                firmware.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        return url
    }
}
