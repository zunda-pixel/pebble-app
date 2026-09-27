import PebbleProtocol
@testable import PebbleTransport
import Foundation
import SwiftUI
import Testing
import ZIPFoundation
@testable import PebbleApp

/// Choosing and starting a firmware update.
@Suite
@MainActor
struct FirmwareLifecycleTests {
    private func makeModel(client: any WatchClient, directory: URL, watchStore: SavedWatchStore? = nil) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: watchStore ?? SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    private func watch(_ id: String = "watch-1") -> ConnectedWatch {
        ConnectedWatch(
            id: WatchID(id),
            name: "My Pebble",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v4.9.142",
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )
    }

    /// Stages an update the way choosing a file does: the package kept in the
    /// firmware folder, and a journal naming it.
    @discardableResult
    private func stage(
        versionTag: String? = nil,
        for watchID: WatchID,
        on model: AppModel,
        in directory: URL
    ) async throws -> PBZFirmwarePackage {
        let archive = try makeFirmwareArchive(in: directory, versionTag: versionTag)
        let package = try PBZFirmwareImporter.load(from: archive, board: .obelixPVT)
        let fileName = try await model.firmwarePackageStore.fileName(keeping: archive)
        try await model.pendingFirmwareUpdateStore.save(FirmwareUpdateJournal(
            watchID: watchID,
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: versionTag,
            packageFileName: fileName,
            packageSHA256: package.sha256
        ))
        return package
    }

    /// A download on disk, as the firmware folder holds one.
    private func download(_ downloaded: DownloadedFirmware, on model: AppModel) async throws {
        try FileManager.default.createDirectory(
            at: model.firmwarePackageStore.folderURL,
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: model.firmwarePackageStore.url(for: downloaded))
        model.firmware.downloads = await model.firmwarePackageStore.downloads()
    }

    @Test
    func firmwareChosenWhileDisconnectedWaitsForTheWatch() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        // A watch running recovery firmware stays connected for only a few
        // seconds, so the file has to be accepted while it is away.
        try await watchStore.record(watch("recovery-watch"))
        let model = makeModel(client: client, directory: directory, watchStore: watchStore)
        await model.loadSavedWatches()
        let firmwareURL = try makeFirmwareArchive(in: directory)

        await model.installFirmware(from: firmwareURL, watchID: WatchID("recovery-watch"))

        let journal = try #require(model.firmware[WatchID("recovery-watch")].journal)
        #expect(journal.watchID == WatchID("recovery-watch"))
        #expect(client.installedFirmwarePackages.isEmpty)
        // Kept as its own copy, so the reader's file can go and the update
        // still has its package when the watch comes back.
        try FileManager.default.removeItem(at: firmwareURL)
        #expect(try await model.pendingFirmwareUpdateStore.package(for: journal) != nil)

        await model.discardPendingFirmwareUpdate(watchID: WatchID("recovery-watch"))
        #expect(!FileManager.default.fileExists(
            atPath: model.firmwarePackageStore.url(for: journal.packageFileName).path(percentEncoded: false)
        ))
    }

    /// What is staged is found again by a fresh launch, from inside the
    /// storage directory and by name alone — an absolute address would point
    /// into the container iOS moves on an update or a restore.
    @Test
    func aStagedUpdateIsFoundAgainAfterARelaunchByNameAlone() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        try await watchStore.record(watch())
        let model = makeModel(client: client, directory: directory, watchStore: watchStore)
        await model.loadSavedWatches()
        await model.installFirmware(from: try makeFirmwareArchive(in: directory), watchID: watch().id)

        let relaunched = makeModel(client: client, directory: directory)
        await relaunched.loadFirmwareState()

        let journal = try #require(relaunched.firmware[watch().id].journal)
        #expect(!journal.packageFileName.contains("/"))
        #expect(relaunched.firmwarePackageStore.folderURL.path(percentEncoded: false)
            .hasPrefix(directory.path(percentEncoded: false)))
        #expect(try await relaunched.pendingFirmwareUpdateStore.package(for: journal) != nil)
        let written = try String(contentsOf: directory.appending(path: "firmware-updates.json"), encoding: .utf8)
        #expect(!written.contains(directory.path(percentEncoded: false)))
    }

    /// Two watches, two screens: what one watch was told, and what it has
    /// waiting, is not on the other's.
    @Test
    func eachWatchKeepsItsOwnUpdateAndItsOwnAnswers() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watchStore = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        try await watchStore.record(watch("a"))
        let model = makeModel(client: client, directory: directory, watchStore: watchStore)
        await model.loadSavedWatches()
        try await stage(versionTag: "v4.37.0", for: WatchID("b"), on: model, in: directory)
        await model.loadFirmwareState()

        await model.installFirmware(from: try makeFirmwareArchive(in: directory), watchID: WatchID("a"))
        // A watch nothing is known about has no board, and says so on its own.
        await model.checkForFirmwareUpdate(watchID: WatchID("unknown"))

        #expect(model.firmware[WatchID("a")].journal?.watchID == WatchID("a"))
        #expect(model.firmware[WatchID("b")].journal?.targetVersion == "v4.37.0")
        #expect(model.firmware[WatchID("unknown")].feedback?.isFailure == true)
        #expect(model.firmware[WatchID("a")].feedback?.isFailure == false)
        #expect(model.firmware[WatchID("b")].feedback == nil)

        await model.discardPendingFirmwareUpdate(watchID: WatchID("a"))
        #expect(model.firmware[WatchID("a")].journal == nil)
        #expect(try await model.pendingFirmwareUpdateStore.journal(for: WatchID("b")) != nil)
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
        let model = makeModel(client: client, directory: directory)
        let connection = WatchConnection(client: client, watch: watch())
        let package = try await stage(for: watch().id, on: model, in: directory)

        let running = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        model.firmwareUpdateTask = running

        try await model.performFirmwareUpdate(package, on: connection)

        #expect(client.installedFirmwarePackages.isEmpty)
        // The transfer that is already running still owns the slot, and no
        // progress display was hijacked from it.
        #expect(model.firmwareUpdateTask != nil)
        #expect(model.firmwareTransferProgress(on: watch().id) == nil)
        #expect(model.firmware[watch().id].feedback == .failure("This firmware is already being transferred."))

        running.cancel()
        await model.discardPendingFirmwareUpdate(watchID: watch().id)
    }

    @Test
    func aFinishedInstallTakesTheDownloadedPackageWithIt() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)
        let downloaded = DownloadedFirmware(versionTag: "v4.36.2", board: .obelixPVT)
        try await download(downloaded, on: model)

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch()))

        // Otherwise the firmware screen goes on offering an install of what the
        // watch is at that moment restarting into.
        #expect(model.firmware.downloads.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: model.firmwarePackageStore.url(for: downloaded).path(percentEncoded: false)
        ))
    }

    @Test
    func aDownloadForAnotherVersionSurvivesAnInstall() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)
        // A watch installing firmware from a file is no reason to throw away a
        // download meant for another watch, or for the next release.
        let downloaded = DownloadedFirmware(versionTag: "v4.37.0", board: .obelixPVT)
        try await download(downloaded, on: model)

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch()))

        #expect(model.firmware.downloads == [downloaded])
        #expect(FileManager.default.fileExists(
            atPath: model.firmwarePackageStore.url(for: downloaded).path(percentEncoded: false)
        ))
    }

    @Test
    func aWatchBackFromItsUpdateIsNoLongerWaitingForARestart() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)

        try await model.performFirmwareUpdate(package, on: WatchConnection(client: client, watch: watch()))
        #expect(model.firmware[watch().id].journal?.phase == .awaitingRestart)

        await model.recordConnectedWatch(watch())

        // The journal is already gone from disk, so nothing but the watch
        // itself can end this: left alone the firmware screen kept offering
        // Stop and Try Again for an update that had finished, and the watch's
        // own row went on saying an update was waiting.
        #expect(model.firmware[watch().id].journal == nil)
        #expect(model.firmware[watch().id].feedback == nil)
    }

    @Test
    func choosingAnotherPackageDuringATransferLeavesTheStagedOneAlone() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)
        let running = Task<Void, any Error> { try await Task.sleep(for: .seconds(60)) }
        model.firmwareUpdateTask = running

        await model.installFirmware(from: try makeFirmwareArchive(in: directory), watchID: watch().id)

        #expect(try await model.pendingFirmwareUpdateStore.journal(for: watch().id)?.packageSHA256 == package.sha256)
        #expect(model.firmware[watch().id].feedback == .failure("This firmware is already being transferred."))

        running.cancel()
        model.firmwareUpdateTask = nil
        await model.discardPendingFirmwareUpdate(watchID: watch().id)
    }

    @Test
    func aCancelledTransferFinishingLateLeavesTheNextOneRunning() async throws {
        let client = SuspendingWatchClient()
        // The second outlasts the first by far more than the cancel and the
        // restart take, so it is still running when the first one ends.
        client.firmwareTransferTimes = [.milliseconds(300), .seconds(1)]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let connection = WatchConnection(client: client, watch: watch())
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)

        let first = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }
        await model.cancelFirmwareUpdate(watchID: watch().id)
        let second = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }

        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(model.firmwareUpdateTask != nil)
        #expect(connection.transferProgress(for: .firmware) != nil)

        try await second.value
        #expect(model.firmwareUpdateTask == nil)
        await model.discardPendingFirmwareUpdate(watchID: watch().id)
    }

    @Test(.timeLimit(.minutes(1)))
    func forgettingAnUpdateMidTransferEndsTheLinkAndFreesTheNextInstall() async throws {
        let client = SuspendingWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let connection = try #require(model.activeConnections.first)
        let watchID = connection.watch.id
        let package = try await stage(versionTag: "v4.36.2", for: watchID, on: model, in: directory)
        client.nextFirmwareTransferEndsWithTheLink = true

        let transfer = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }
        await model.discardPendingFirmwareUpdate(watchID: watchID)

        #expect(client.disconnectedWatches.map(\.id) == [watchID])
        await #expect(throws: CancellationError.self) { try await transfer.value }
        #expect(model.firmware[watchID].journal == nil)
        #expect(model.firmware[watchID].feedback == .success("Firmware transfer stopped and the pending update removed."))

        await model.connect(to: discovered)
        let reconnected = try #require(model.activeConnections.first)
        let next = try await stage(versionTag: "v4.36.2", for: watchID, on: model, in: directory)
        try await model.performFirmwareUpdate(next, on: reconnected)
        #expect(model.firmware[watchID].journal?.phase == .awaitingRestart)
    }

    /// Stopping one watch's update is no business of another watch's transfer.
    @Test
    func stoppingOneWatchsUpdateLeavesAnothersTransferRunning() async throws {
        let client = SuspendingWatchClient()
        client.firmwareTransferTimes = [.seconds(1)]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let connection = WatchConnection(client: client, watch: watch())
        let package = try await stage(versionTag: "v4.36.2", for: watch().id, on: model, in: directory)
        try await stage(versionTag: "v4.37.0", for: WatchID("other"), on: model, in: directory)

        let transfer = Task { try await model.performFirmwareUpdate(package, on: connection) }
        while model.firmwareUpdateTask == nil { try await Task.sleep(for: .milliseconds(5)) }
        await model.discardPendingFirmwareUpdate(watchID: WatchID("other"))

        #expect(model.firmwareUpdateTask != nil)
        try await transfer.value
        #expect(model.firmware[watch().id].journal?.phase == .awaitingRestart)
    }

    @Test
    func anotherBoardsDownloadIsNotInstalledOnThisWatch() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let board = try #require(model.board(for: discovered.id))
        let otherBoard = try #require(WatchBoard.allCases.first { $0 != board })
        try await download(DownloadedFirmware(versionTag: "v4.37.0", board: otherBoard), on: model)

        await model.installDownloadedFirmware(watchID: discovered.id)

        #expect(model.downloadedFirmware(for: discovered.id) == nil)
        #expect(model.firmware[discovered.id].journal == nil)
        #expect(client.installedFirmwarePackages.isEmpty)
        #expect(model.firmware[discovered.id].feedback?.isFailure == true)
    }

    @Test
    func confirmingARecoveryUpdateForAnAbsentWatchSaysSo() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let away = WatchID("away")
        try await stage(for: away, on: model, in: directory)
        model.firmware[away].requiresConfirmation = true

        await model.confirmRecoveryFirmwareUpdate(watchID: away)

        #expect(model.firmware[away].feedback?.isFailure == true)
        #expect(model.firmware[away].requiresConfirmation)
        #expect(client.installedFirmwarePackages.isEmpty)
        await model.discardPendingFirmwareUpdate(watchID: away)
    }

    private func makeFirmwareArchive(in directory: URL, versionTag: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "firmware-\(UUID().uuidString).pbz")
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
            "crc": \(PebbleCRC32.calculate([UInt8](firmware)))\(versionTag.map { ",\n    \"versionTag\": \"\($0)\"" } ?? "")
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
