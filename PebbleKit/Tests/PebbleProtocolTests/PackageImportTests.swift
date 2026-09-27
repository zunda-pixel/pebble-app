import Foundation
import Testing
import ZIPFoundation
@testable import PebbleProtocol

/// Reading application and firmware packages.
@Suite
@MainActor
struct PackageImportTests {
    @Test func pbwBinaryHeaderProvidesBlobDBMetadata() throws {
        var bytes = [UInt8](repeating: 0, count: PBWBinaryHeaderDecoder.size)
        bytes.replaceSubrange(0..<8, with: [0x50, 0x42, 0x4C, 0x41, 0x50, 0x50, 0, 0])
        bytes.replaceSubrange(8..<14, with: [1, 0, 4, 2, 3, 7])
        bytes.replaceSubrange(88..<92, with: [0x78, 0x56, 0x34, 0x12])
        bytes.replaceSubrange(96..<100, with: [0xEF, 0xCD, 0xAB, 0x90])
        bytes.replaceSubrange(104..<120, with: [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])

        let header = try PBWBinaryHeaderDecoder.decode(from: Data(bytes))
        let metadata = header.appMetadata(name: "Orbit")

        #expect(header.headerVersionMajor == 1)
        #expect(header.sdkVersionMajor == 4)
        #expect(header.sdkVersionMinor == 2)
        #expect(header.appVersionMajor == 3)
        #expect(header.appVersionMinor == 7)
        #expect(header.iconResourceID == 0x12345678)
        #expect(header.flags == 0x90ABCDEF)
        #expect(metadata.applicationID.uuidString == "00112233-4455-6677-8899-AABBCCDDEEFF")
        #expect(metadata.name == "Orbit")
    }

    @Test func pbwBinaryHeaderRejectsInvalidInput() {
        #expect(throws: PBWBinaryHeaderError.invalidSize) {
            try PBWBinaryHeaderDecoder.decode(from: Data())
        }
        #expect(throws: PBWBinaryHeaderError.invalidSentinel) {
            try PBWBinaryHeaderDecoder.decode(from: Data(repeating: 0, count: PBWBinaryHeaderDecoder.size))
        }
    }

    @Test func invalidPBWArchiveIsRejected() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pbw")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data("not a zip archive".utf8).write(to: fileURL)

        #expect(throws: (any Error).self) {
            try PBWPackageImporter.load(from: fileURL, for: .pebbleTime2)
        }
    }

    @Test func pbwManifestSelectsBestVariantAndTransferOrder() throws {
        let basalt = Data(#"""
        {
          "application": { "name": "app.bin", "size": 12 },
          "resources": { "name": "app.pbpack", "size": 8 }
        }
        """#.utf8)
        let emery = Data(#"""
        {
          "application": {
            "crc": 305419896,
            "name": "app.bin",
            "sdk_version": { "major": 4, "minor": 0 },
            "size": 24
          },
          "resources": { "name": "app.pbpack", "size": 16 },
          "worker": { "name": "worker.bin", "size": 4 }
        }
        """#.utf8)

        let plan = try PBWManifestDecoder.installationPlan(
            for: .pebbleTime2,
            manifestsByVariant: [.basalt: basalt, .emery: emery]
        )

        #expect(plan.variant == .emery)
        #expect(plan.objects.map(\.objectType) == [.appExecutable, .appResource, .worker])
        #expect(plan.objects.map(\.blob.name) == ["app.bin", "app.pbpack", "worker.bin"])
    }

    @Test func pbwManifestRejectsUnsupportedWatchVariant() {
        let chalk = Data(#"""
        { "application": { "name": "app.bin", "size": 12 } }
        """#.utf8)

        #expect(throws: PBWManifestError.noCompatibleVariant) {
            try PBWManifestDecoder.installationPlan(
                for: .pebble2Duo,
                manifestsByVariant: [.chalk: chalk]
            )
        }
    }

    @Test func pbwAppInfoDecodesWatchfaceMetadata() throws {
        let json = Data(#"""
        {
          "uuid": "00112233-4455-6677-8899-aabbccddeeff",
          "shortName": "Orbit",
          "longName": "Orbit Face",
          "companyName": "Pebble",
          "versionCode": 3.5,
          "versionLabel": "3.5",
          "capabilities": ["configurable"],
          "targetPlatforms": ["emery", "basalt"],
          "watchapp": { "watchface": true }
        }
        """#.utf8)

        let application = try PBWApplicationDecoder.decodeAppInfo(from: json)

        #expect(application.displayName == "Orbit Face")
        #expect(application.kind == .watchface)
        #expect(application.bestVariant(for: .pebbleTime2) == .emery)
        #expect(application.bestVariant(for: .pebble2Duo) == nil)
    }

    /// A name no watch this app drives can run is dropped where it is read,
    /// rather than carried along as a string nothing can match.
    @Test func aPlatformNameNoWatchHereRunsIsDropped() throws {
        #expect(WatchPlatform.known(in: ["emery", "obelix", "basalt"]) == [.emery, .basalt])
        let json = Data(#"""
        {
          "uuid": "00112233-4455-6677-8899-aabbccddeeff",
          "shortName": "Odd",
          "versionLabel": "1.0",
          "targetPlatforms": ["obelix", "emery"]
        }
        """#.utf8)

        let application = try PBWApplicationDecoder.decodeAppInfo(from: json)

        #expect(application.targetPlatforms == [.emery])
    }

    @Test func eachModelTriesItsOwnPlatformFirst() {
        #expect(WatchModel.pebble2Duo.compatiblePlatforms == [.flint, .diorite, .aplite])
        #expect(WatchModel.pebbleTime2.compatiblePlatforms == [.emery, .basalt, .diorite, .aplite])
        #expect(WatchModel.pebbleRound2.compatiblePlatforms == [.gabbro, .chalk])
        #expect(WatchModel.allCases.allSatisfy { $0.platform == $0.compatiblePlatforms[0] })
    }

    @Test func legacyPBWDefaultsToApliteAndWatchapp() throws {
        let json = Data(#"""
        {
          "uuid": "00112233-4455-6677-8899-aabbccddeeff",
          "shortName": "Legacy",
          "versionLabel": "1.0"
        }
        """#.utf8)

        let application = try PBWApplicationDecoder.decodeAppInfo(from: json)

        #expect(application.targetPlatforms == [.aplite])
        #expect(application.kind == .watchapp)
        #expect(application.bestVariant(for: .pebble2Duo) == .aplite)
    }

    @Test func firmwareImporterPicksTheManifestForTheTargetSlot() throws {
        let firmware = Data([9, 8, 7, 6])
        let url = try makeDualSlotFirmwareArchive(firmware: firmware)
        defer { try? FileManager.default.removeItem(at: url) }

        let forSlotOne = try PBZFirmwareImporter.load(from: url, board: .obelixPVT, targetSlot: 1)
        #expect(forSlotOne.manifest.firmware.slot == 1)

        let forSlotZero = try PBZFirmwareImporter.load(from: url, board: .obelixPVT, targetSlot: 0)
        #expect(forSlotZero.manifest.firmware.slot == 0)

        // Without a known slot the first matching manifest is good enough.
        #expect(throws: Never.self) {
            try PBZFirmwareImporter.load(from: url, board: .obelixPVT)
        }
        // A package holding only the running slot is reported as such.
        #expect(throws: PBZFirmwareError.wrongFirmwareSlot) {
            try PBZFirmwareImporter.load(from: url, board: .obelixPVT, targetSlot: 2)
        }
    }

    private func makeDualSlotFirmwareArchive(firmware: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).pbz")
        let archive = try Archive(url: url, accessMode: .create)
        let crc = PebbleCRC32.calculate([UInt8](firmware))
        for slot in 0...1 {
            let manifest = """
            {
              "manifestVersion": 1,
              "firmware": {
                "name": "firmware.bin",
                "type": "normal",
                "hwrev": "\(WatchBoard.obelixPVT.rawValue)",
                "size": \(firmware.count),
                "crc": \(crc),
                "slot": \(slot)
              }
            }
            """
            let manifestBytes = Data(manifest.utf8)
            try archive.addEntry(
                with: "slot\(slot)/manifest.json",
                type: .file,
                uncompressedSize: Int64(manifestBytes.count),
                provider: { position, size in
                    manifestBytes.subdata(in: Int(position)..<Int(position) + size)
                }
            )
            try archive.addEntry(
                with: "slot\(slot)/firmware.bin",
                type: .file,
                uncompressedSize: Int64(firmware.count),
                provider: { position, size in
                    firmware.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        return url
    }

    @Test func firmwareImporterRejectsAnotherBoardsPackage() throws {
        let firmware = Data([9, 8, 7, 6])
        let url = try makeDualSlotFirmwareArchive(firmware: firmware)
        defer { try? FileManager.default.removeItem(at: url) }

        // Boards sharing a watch model still run their own firmware, so a
        // package built for one must not be accepted for another.
        #expect(throws: PBZFirmwareError.incompatibleHardware) {
            try PBZFirmwareImporter.load(from: url, board: .obelixDVT)
        }
    }

    @Test(arguments: [
        (UInt8(15), WatchBoard?.some(.asterix)),
        (UInt8(18), WatchBoard?.some(.obelixPVT)),
        (UInt8(21), WatchBoard?.some(.getafixDVT2)),
        (UInt8(243), WatchBoard?.some(.obelixBigboard2)),
        (UInt8(200), WatchBoard?.none),
    ])
    func boardIsReadFromTheHardwarePlatform(platform: UInt8, board: WatchBoard?) {
        #expect(WatchBoard(hardwarePlatform: platform) == board)
    }

    @Test
    func firmwareUpdateTargetsTheSlotThatIsNotRunning() {
        let slot0 = ConnectedWatch(
            id: WatchID("a"),
            name: "P",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: nil,
                serialNumber: nil,
                hardwarePlatform: 18,
                runningFirmwareSlot: 0
            )
        )
        let slot1 = ConnectedWatch(
            id: WatchID("b"),
            name: "P",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: nil,
                serialNumber: nil,
                hardwarePlatform: 18,
                runningFirmwareSlot: 1
            )
        )
        let single = ConnectedWatch(
            id: WatchID("c"),
            name: "P",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: nil,
                serialNumber: nil,
                hardwarePlatform: 18
            )
        )

        #expect(slot0.firmwareUpdateSlot == 1)
        #expect(slot1.firmwareUpdateSlot == 0)
        #expect(single.firmwareUpdateSlot == nil)
    }

    @Test func firmwareCatalogPicksThePackageCoveringEverySlot() {
        let assets = [
            GitHubReleaseAsset(name: "firmware_obelix_pvt_v4.36.2_slot0.bin", size: 1, browserDownloadURL: URL(string: "https://example.invalid/a")!),
            GitHubReleaseAsset(name: "normal_obelix_pvt_v4.36.2_slot0.pbz", size: 2, browserDownloadURL: URL(string: "https://example.invalid/b")!),
            GitHubReleaseAsset(name: "normal_obelix_pvt_v4.36.2_slot1.pbz", size: 3, browserDownloadURL: URL(string: "https://example.invalid/c")!),
            GitHubReleaseAsset(name: "normal_obelix_pvt_v4.36.2.pbz", size: 4, browserDownloadURL: URL(string: "https://example.invalid/d")!),
            GitHubReleaseAsset(name: "recovery_obelix_pvt_v4.36.2.pbz", size: 5, browserDownloadURL: URL(string: "https://example.invalid/e")!),
        ]

        let chosen = PebbleOSFirmwareCatalog.asset(for: .obelixPVT, in: assets)

        #expect(chosen?.name == "normal_obelix_pvt_v4.36.2.pbz")
        // A board whose name is a prefix of another must not match it.
        #expect(PebbleOSFirmwareCatalog.asset(for: .obelixDVT, in: assets) == nil)
        #expect(PebbleOSFirmwareCatalog.asset(for: .asterix, in: assets) == nil)
    }

    /// Two slots with different bytes, so which one was read can be told.
    private func makeFirmwareArchive(slotImages: [Data], in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).pbz")
        let archive = try Archive(url: url, accessMode: .create)
        for (slot, firmware) in slotImages.enumerated() {
            let manifest = Data("""
            {
              "manifestVersion": 1,
              "firmware": {
                "name": "firmware.bin",
                "type": "normal",
                "hwrev": "\(WatchBoard.obelixPVT.rawValue)",
                "size": \(firmware.count),
                "crc": \(PebbleCRC32.calculate([UInt8](firmware))),
                "slot": \(slot),
                "versionTag": "v4.37.0"
              }
            }
            """.utf8)
            try archive.addEntry(
                with: "slot\(slot)/manifest.json",
                type: .file,
                uncompressedSize: Int64(manifest.count),
                provider: { position, size in manifest.subdata(in: Int(position)..<Int(position) + size) }
            )
            try archive.addEntry(
                with: "slot\(slot)/firmware.bin",
                type: .file,
                uncompressedSize: Int64(firmware.count),
                provider: { position, size in firmware.subdata(in: Int(position)..<Int(position) + size) }
            )
        }
        return url
    }

    private func journal(
        for watchID: WatchID,
        package: PBZFirmwarePackage,
        fileName: String,
        slot: Int? = nil
    ) -> FirmwareUpdateJournal {
        FirmwareUpdateJournal(
            watchID: watchID,
            board: .obelixPVT,
            slot: slot,
            previousVersion: nil,
            targetVersion: package.manifest.firmware.versionTag,
            packageFileName: fileName,
            packageSHA256: package.sha256
        )
    }

    /// The package is kept once, as a file in the storage directory, and the
    /// journal names it: nothing of it is copied into JSON, and nothing points
    /// at an absolute address that an update of the app would move.
    @Test func aStagedUpdateIsReadAgainFromItsFileForTheSlotItWasChosenFor() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = StorageDirectory(url: root)
        let packages = FirmwarePackageStore(directory: directory)
        let updates = PendingFirmwareUpdateStore(directory: directory)
        let chosen = try makeFirmwareArchive(
            slotImages: [Data([1, 1, 1, 1]), Data([2, 2, 2, 2])],
            in: root.appending(path: "Downloads")
        )
        let package = try PBZFirmwareImporter.load(from: chosen, board: .obelixPVT, targetSlot: 1)

        let fileName = try await packages.fileName(keeping: chosen)
        try FileManager.default.removeItem(at: chosen)
        try await updates.save(journal(for: WatchID("watch"), package: package, fileName: fileName, slot: 1))

        #expect(FileManager.default.fileExists(atPath: packages.url(for: fileName).path(percentEncoded: false)))
        let staged = try #require(try await updates.journal(for: WatchID("watch")))
        #expect(staged.packageFileName == fileName)
        let reread = try #require(try await updates.package(for: staged))
        #expect(reread.firmware == Data([2, 2, 2, 2]))
        #expect(reread.sha256 == package.sha256)
        try await updates.updatePhase(.transferring, watchID: WatchID("watch"))
        #expect(try await updates.journal(for: WatchID("watch"))?.phase == .transferring)
    }

    @Test func eachWatchKeepsItsOwnUpdateAndClearingOneTakesOnlyItsCopy() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = StorageDirectory(url: root)
        let packages = FirmwarePackageStore(directory: directory)
        let updates = PendingFirmwareUpdateStore(directory: directory)
        let chosen = try makeFirmwareArchive(slotImages: [Data([3, 3, 3, 3])], in: root.appending(path: "In"))
        let package = try PBZFirmwareImporter.load(from: chosen, board: .obelixPVT)
        let first = try await packages.fileName(keeping: chosen)
        let second = try await packages.fileName(keeping: chosen)
        try await updates.save(journal(for: WatchID("a"), package: package, fileName: first))
        try await updates.save(journal(for: WatchID("b"), package: package, fileName: second))

        try await updates.clear(watchID: WatchID("a"))

        #expect(try await updates.journal(for: WatchID("a")) == nil)
        let remaining = try #require(try await updates.journal(for: WatchID("b")))
        #expect(remaining.packageFileName == second)
        #expect(!FileManager.default.fileExists(atPath: packages.url(for: first).path(percentEncoded: false)))
        #expect(try await updates.package(for: remaining) != nil)
    }

    /// A download is the downloads' to keep: the update that read it going
    /// away leaves it where it is.
    @Test func aDownloadIsKnownByItsFileAndOutlivesAnUpdateThatUsedIt() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = StorageDirectory(url: root)
        let packages = FirmwarePackageStore(directory: directory)
        let updates = PendingFirmwareUpdateStore(directory: directory)
        let downloaded = DownloadedFirmware(versionTag: "v4.37.0-rc1", board: .obelixPVT)
        let archive = try makeFirmwareArchive(slotImages: [Data([4, 4, 4, 4])], in: root.appending(path: "In"))
        try FileManager.default.createDirectory(at: packages.folderURL, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: archive, to: packages.url(for: downloaded))

        #expect(await packages.downloads() == [downloaded])
        let fileName = try await packages.fileName(keeping: packages.url(for: downloaded))
        #expect(fileName == downloaded.fileName)
        let package = try PBZFirmwareImporter.load(from: packages.url(for: downloaded), board: .obelixPVT)
        try await updates.save(journal(for: WatchID("watch"), package: package, fileName: fileName))

        try await updates.clear(watchID: WatchID("watch"))

        #expect(await packages.downloads() == [downloaded])
    }

    @Test func aStagedUpdateWhosePackageHasGoneHasNoPackage() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = StorageDirectory(url: root)
        let packages = FirmwarePackageStore(directory: directory)
        let updates = PendingFirmwareUpdateStore(directory: directory)
        let chosen = try makeFirmwareArchive(slotImages: [Data([5, 5, 5, 5])], in: root.appending(path: "In"))
        let package = try PBZFirmwareImporter.load(from: chosen, board: .obelixPVT)
        let fileName = try await packages.fileName(keeping: chosen)
        let staged = journal(for: WatchID("watch"), package: package, fileName: fileName)
        try await updates.save(staged)

        await packages.remove(fileName: fileName)

        #expect(try await updates.package(for: staged) == nil)
    }

    @Test func aDownloadedPackageNameReadsBackAsItsBoardAndVersion() {
        let downloaded = DownloadedFirmware(versionTag: "v4.37.0", board: .obelixBigboard2)

        #expect(downloaded.fileName == "pebbleos-obelix_bb2-v4.37.0.pbz")
        #expect(DownloadedFirmware(fileName: downloaded.fileName) == downloaded)
        #expect(DownloadedFirmware(fileName: "chosen-\(UUID().uuidString).pbz") == nil)
        #expect(DownloadedFirmware(fileName: "pebbleos-nosuchboard-v1.pbz") == nil)
    }

    @Test func aManifestImageTypeTheWatchDoesNotInstallIsUnsafe() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "odd.pbz")
        let archive = try Archive(url: url, accessMode: .create)
        let manifest = Data("""
        {"manifestVersion": 1, "firmware": {"name": "firmware.bin", "type": "bootloader",
         "hwrev": "obelix_pvt", "size": 1, "crc": 1}}
        """.utf8)
        try archive.addEntry(
            with: "manifest.json",
            type: .file,
            uncompressedSize: Int64(manifest.count),
            provider: { position, size in manifest.subdata(in: Int(position)..<Int(position) + size) }
        )

        #expect(throws: PBZFirmwareError.unsafeManifest) {
            try PBZFirmwareImporter.load(from: url, board: .obelixPVT)
        }
    }

    @Test func aRecoveryImageIsSentAsRecovery() {
        let blob = PBZFirmwareBlob(
            name: "firmware.bin", type: .recovery, boardName: "obelix_pvt",
            size: 1, crc: 1, versionTag: nil, slot: nil
        )
        #expect(blob.objectType == .recovery)
        var normal = blob
        normal.type = .normal
        #expect(normal.objectType == .firmware)
    }

    @Test func aManifestBoardNameMatchesItsBoardWhateverItsCase() {
        let blob = PBZFirmwareBlob(
            name: "firmware.bin", type: .normal, boardName: "OBELIX_PVT",
            size: 1, crc: 1, versionTag: nil, slot: nil
        )
        #expect(blob.board == .obelixPVT)
    }
}
