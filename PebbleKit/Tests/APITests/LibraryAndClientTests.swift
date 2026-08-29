import Foundation
import Testing
import ZIPFoundation
@testable import API

@Suite
@MainActor
struct LibraryAndClientTests {

    @Test func applicationLibraryPersistsUpdatesAndOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleApplicationLibrary(fileURL: fileURL)
        let first = PebbleApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "First",
            longName: "",
            companyName: "Pebble",
            versionCode: 1,
            versionLabel: "1.0",
            capabilities: [],
            targetPlatforms: ["aplite"],
            kind: .watchapp
        )
        var second = first
        second.id = try #require(UUID(uuidString: "10213243-5465-7687-98A9-BACBDCEDFE0F"))
        second.shortName = "Second"

        _ = try await library.upsert(first)
        _ = try await library.upsert(second)
        _ = try await library.reorder(applicationIDs: [second.id, first.id])

        let reloaded = PebbleApplicationLibrary(fileURL: fileURL)
        #expect(try await reloaded.applications().map(\.id) == [second.id, first.id])
        _ = try await reloaded.remove(applicationID: second.id)
        #expect(try await reloaded.applications() == [first])
    }

    @Test func applicationLibrarySnapshotRestoresMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleApplicationLibrary(fileURL: fileURL)
        let application = PebbleApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "Original",
            longName: "",
            companyName: "Pebble",
            versionCode: 1,
            versionLabel: "1.0",
            capabilities: [],
            targetPlatforms: ["aplite"],
            kind: .watchapp
        )
        _ = try await library.upsert(application)
        let snapshot = try await library.snapshot(applicationID: application.id)
        var updated = application
        updated.shortName = "Updated"
        updated.versionLabel = "2.0"
        _ = try await library.upsert(updated)

        let restored = try await library.restore(snapshot)

        #expect(restored == [application])
        #expect(try await library.applications() == [application])
    }

    @Test func applicationLibraryPersistsPerWatchSynchronizationState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstID = UUID()
        let secondID = UUID()
        let library = PebbleApplicationLibrary(fileURL: fileURL)

        try await library.setSynchronizedApplicationIDs([firstID, secondID], deviceID: "watch-a")
        try await library.setSynchronizedApplicationIDs([secondID], deviceID: "watch-b")
        let reloaded = PebbleApplicationLibrary(fileURL: fileURL)

        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "watch-a") == [firstID, secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "watch-b") == [secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(deviceID: "unknown") == [])
    }

    @Test
    func mockClientDiscoversOnlySupportedModels() async throws {
        let client = MockPebbleClient()
        let devices = try await client.scan()

        #expect(devices.count == PebbleWatchModel.allCases.count)
        #expect(Set(devices.map(\.model)) == Set(PebbleWatchModel.allCases))
    }

    @Test
    func mockClientConnectsToDiscoveredDevice() async throws {
        let client = MockPebbleClient()
        let discoveredDevice = try #require(await client.scan().first)
        let connectedDevice = try await client.connect(to: discoveredDevice)

        #expect(connectedDevice.id == discoveredDevice.id)
        #expect(connectedDevice.model == discoveredDevice.model)
        #expect(connectedDevice.batteryLevel == 84)
    }

    @Test
    func mockClientRecordsAppMessagesAndResponses() async throws {
        let client = MockPebbleClient()
        let applicationID = UUID()
        let tuples = [AppMessageTuple(key: 7, value: .string("value"))]

        try await client.sendAppMessage(applicationID: applicationID, tuples: tuples)
        try await client.respondToAppMessage(transactionID: 9, acknowledged: true)

        #expect(client.sentAppMessages.count == 1)
        #expect(client.sentAppMessages.first?.applicationID == applicationID)
        #expect(client.sentAppMessages.first?.tuples == tuples)
        #expect(client.appMessageResponses.first?.transactionID == 9)
        #expect(client.appMessageResponses.first?.acknowledged == true)
    }

    @Test
    func diagnosticsKeepsBoundedHistoryAndExportsReport() async throws {
        let diagnostics = PebbleDiagnostics(maximumEntryCount: 2)
        await diagnostics.recordFrame(
            direction: "out",
            frame: PebbleProtocolFrame(endpoint: 48, payload: Array("private-token".utf8))
        )
        let packetEntry = try #require(await diagnostics.snapshot().last)
        #expect(!packetEntry.message.contains("private-token"))
        await diagnostics.record(category: "test", message: "first")
        await diagnostics.record(.warning, category: "test", message: "second")
        await diagnostics.record(.error, category: "test", message: "third")

        let entries = await diagnostics.snapshot()
        #expect(entries.map(\.message) == ["second", "third"])

        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = try await diagnostics.exportReport(
            device: nil,
            applications: [],
            directory: directory
        )
        #expect(FileManager.default.fileExists(atPath: reportURL.path))
        #expect(try Data(contentsOf: reportURL).isEmpty == false)
    }

    @Test
    func applicationLibraryMetadataDecodesOlderSnapshots() throws {
        let id = UUID()
        let data = Data("""
        [{"id":"\(id.uuidString)","shortName":"Old","longName":"","companyName":"",\
        "versionLabel":"1.0","capabilities":[],"targetPlatforms":["aplite"],"kind":"watchapp"}]
        """.utf8)

        let application = try #require(JSONDecoder().decode([PebbleApplication].self, from: data).first)

        #expect(application.appKeys.isEmpty)
        #expect(application.hasCompanionJavaScript == false)
        #expect(application.isConfigurable == false)
    }

    @Test
    func mockClientRecordsTimelineNotifications() async throws {
        let client = MockPebbleClient()
        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: "Title",
            body: "Body",
            appName: nil
        )

        try await client.sendNotification(notification)

        #expect(client.sentNotifications == [notification])
    }
}

@Suite
struct PebbleWatchLibraryTests {
    @Test func recordsUpdatesPreferencesAndForgetsWatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "watches.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleWatchLibrary(fileURL: fileURL)
        let device = PebbleDevice(
            id: "watch-1",
            name: "Pebble QEMU",
            model: .pebbleTime2,
            firmwareVersion: "v1",
            batteryLevel: 75,
            serialNumber: "SERIAL"
        )

        var watches = try await library.record(device)
        #expect(watches.count == 1)
        #expect(watches[0].automaticallyConnects)
        #expect(watches[0].lastBatteryLevel == 75)

        watches = try await library.setAutomaticallyConnects(false, watchID: device.id)
        #expect(!watches[0].automaticallyConnects)

        let reloaded = PebbleWatchLibrary(fileURL: fileURL)
        #expect(try await reloaded.allWatches()[0].firmwareVersion == "v1")
        #expect(try await reloaded.remove(watchID: device.id).isEmpty)
    }
}

@Suite
struct CompanionStorageTests {

    @Test func firmwareUsesSystemPutBytesAndSystemMessages() throws {
        var session = PutBytesTransferSession(bytes: [1, 2, 3], objectType: .firmware, appBankID: 1)
        guard case .send(let initialization) = try session.start() else {
            Issue.record("Expected firmware initialization frame")
            return
        }
        #expect(initialization.payload == [0x01, 0, 0, 0, 3, PutBytesObjectType.firmware.rawValue, 1])
        #expect(SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: 3).payload == [0, 1, 0, 0, 0, 0, 3, 0, 0, 0])
        #expect(SystemMessageCodec.firmwareUpdateCompleteFrame().payload == [0, 2])
    }

    @Test func healthSyncUsesOfficialEndpointAndLittleEndianElapsedTime() {
        let frame = HealthSyncCodec.requestFrame(
            since: Date(timeIntervalSince1970: 100),
            now: Date(timeIntervalSince1970: 0x12345678 + 100)
        )
        #expect(frame.endpoint == 911)
        #expect(frame.payload == [0x01, 0x78, 0x56, 0x34, 0x12])
    }

    @Test func fullHealthSyncUsesMaximumElapsedTime() {
        #expect(HealthSyncCodec.requestFrame(since: nil).payload == [0x01, 0xff, 0xff, 0xff, 0xff])
    }

    @Test func healthDataLoggingDecodesStepSessionAndAcknowledgesPackets() throws {
        var processor = HealthDataLoggingProcessor()
        let openPayload: [UInt8] = [0x01, 7] + Array(repeating: 0, count: 16)
            + [0, 0, 0, 0] + [81, 0, 0, 0] + [0, 15, 0]
        let open = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: openPayload))
        #expect(open.response?.payload == [0x85, 7])

        let item: [UInt8] = [5, 0, 100, 0, 0, 0, 0, 6, 1, 42, 0, 0, 0, 0, 0]
        let sendPayload: [UInt8] = [0x02, 7] + Array(repeating: 0, count: 8) + item
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: sendPayload))
        #expect(result.response?.payload == [0x85, 7])
        #expect(result.samples.count == 1)
        #expect(result.samples[0].steps == 42)
    }

    @Test func unknownHealthDataLoggingSessionIsRejected() throws {
        var processor = HealthDataLoggingProcessor()
        let payload: [UInt8] = [0x02, 9] + Array(repeating: 0, count: 8)
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: payload))
        #expect(result.response?.payload == [0x86, 9])
    }

    @Test func timelinePinEncodesPinTypeAndGenericLayout() throws {
        let pin = PebbleTimelinePin(
            id: UUID(),
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 100),
            title: "Meeting",
            subtitle: nil,
            body: nil
        )
        let bytes = try pin.encoded()
        #expect(bytes[38] == 0x02)
        #expect(bytes[41] == 0x01)
        #expect(try TimelinePinCodec.insertFrame(pin, token: 1).endpoint == BlobDBCodec.endpoint)
    }

    @Test func healthLibraryPersistsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleHealthLibrary(fileURL: url)
        let sample = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 10), steps: 1234, sleepMinutes: 420,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 20)
        )
        try await library.save([sample])
        #expect(try await library.samples() == [sample])
        let replacement = PebbleHealthSample(
            date: sample.date, steps: 2000, sleepMinutes: 400,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 30)
        )
        let merged = try await library.merge([replacement])
        #expect(merged.count == 1)
        #expect(merged[0].steps == 2000)
        #expect(merged[0].sleepMinutes == 400)
        #expect(merged[0].date == Date(timeIntervalSince1970: 0))
    }

    @Test func healthMergeKeepsHighestStepsAndLatestSleep() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PebbleHealthLibrary(fileURL: url)
        let watch = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 100), steps: 8_000, sleepMinutes: 300,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 200)
        )
        let imported = PebbleHealthSample(
            date: Date(timeIntervalSince1970: 200), steps: 7_000, sleepMinutes: 450,
            timeZoneIdentifier: "UTC", source: .imported, updatedAt: Date(timeIntervalSince1970: 300)
        )
        let merged = try await library.merge([watch, imported])
        #expect(merged.count == 1)
        #expect(merged[0].steps == 8_000)
        #expect(merged[0].sleepMinutes == 450)
        #expect(merged[0].source == .imported)
    }

    @Test func healthArchiveRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sourceURL = directory.appending(path: "source.json")
        let destinationURL = directory.appending(path: "destination.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = PebbleHealthLibrary(fileURL: sourceURL)
        try await source.save([PebbleHealthSample(date: .now, steps: 123, sleepMinutes: 45)])
        let archiveURL = try await source.export()
        let destination = PebbleHealthLibrary(fileURL: destinationURL)
        let imported = try await destination.importArchive(from: archiveURL)
        #expect(imported.count == 1)
        #expect(imported[0].steps == 123)
        #expect(imported[0].source == .imported)
    }

    @Test func appRunStateUsesOfficialEndpointAndUUIDPayload() throws {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let frame = AppRunStateCodec.startFrame(applicationID: id)
        #expect(frame.endpoint == 52)
        #expect(frame.payload == [0x01, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        #expect(try AppRunStateCodec.decode(frame) == .started(id))
        #expect(AppRunStateCodec.requestFrame().payload == [0x03])
    }

    @Test func notificationPreferencesApplyMuteAndOvernightQuietHours() {
        let id = UUID()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tenPM = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 22))!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let quiet = NotificationDeliveryPreferences(quietHoursEnabled: true, quietHoursStart: 21, quietHoursEnd: 7)
        #expect(!quiet.permits(applicationID: id, at: tenPM, calendar: calendar))
        #expect(quiet.permits(applicationID: id, at: noon, calendar: calendar))
        let muted = NotificationDeliveryPreferences(mutedApplicationIDs: [id])
        #expect(!muted.permits(applicationID: id, at: noon, calendar: calendar))
    }

    @Test func pendingTimelineOperationsPersist() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "timeline-operations.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PendingTimelineOperationLibrary(fileURL: url)
        let id = UUID()
        try await library.save([.delete(id)])
        #expect(try await library.operations() == [.delete(id)])
    }

    /// Builds a PBZ holding one manifest per slot, as a dual-slot watch's
    /// firmware package does.

    @Test func officialCatalogResponseMapsToInstallableApplication() throws {
        let json = """
        {
          "applications": [{
            "author": "Pebble Developer",
            "category": "Tools & Utilities",
            "description": "A useful app",
            "id": "store-id",
            "title": "Utility",
            "type": "watchapp",
            "uuid": "00112233-4455-6677-8899-aabbccddeeff",
            "hardware_platforms": [{"name":"emery"}],
            "icon_image": {"small":"https://example.com/icon.png"},
            "screenshot_images": [{"emery":"https://example.com/screenshot.png"}],
            "latest_release": {
              "pbw_file":"https://example.com/utility.pbw",
              "release_notes":"Improved reliability",
              "version":"2.0"
            }
          }]
        }
        """
        let home = try JSONDecoder().decode(OfficialCatalogHome.self, from: Data(json.utf8))
        let application = try #require(home.applications.first?.application(kind: .watchapp))
        #expect(application.name == "Utility")
        #expect(application.version == "2.0")
        #expect(application.supports(.pebbleTime2))
        #expect(!application.supports(.pebble2Duo))
        #expect(application.releaseNotes == "Improved reliability")
    }

    @Test func catalogVersionComparisonUsesNumericOrdering() {
        let application = PebbleCatalogApplication(
            id: UUID(), name: "App", developer: "Developer", version: "2.10",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        #expect(application.isNewer(than: "2.9"))
        #expect(!application.isNewer(than: "2.10"))
        #expect(!application.isNewer(than: "3.0"))
    }

    @Test func catalogSnapshotPersistsOfflineMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = PebbleCatalogApplication(
            id: UUID(), name: "Cached", developer: "Developer", version: "1.0",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        let snapshot = PebbleCatalogSnapshot(
            sourceURL: URL(string: "https://example.com/api")!, fetchedAt: Date(timeIntervalSince1970: 100),
            applications: [application]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let catalog = PebbleAppCatalog(cacheURL: url)
        #expect(try await catalog.cachedSnapshot() == snapshot)
    }

    @Test func reconnectBackoffGrowsExponentiallyAndCaps() {
        var backoff = PebbleReconnectBackoff(
            attempt: 0,
            initialDelay: .seconds(2),
            maximumDelay: .seconds(10)
        )

        #expect(backoff.nextDelay() == .seconds(2))
        #expect(backoff.nextDelay() == .seconds(4))
        #expect(backoff.nextDelay() == .seconds(8))
        #expect(backoff.nextDelay() == .seconds(10))
        #expect(backoff.nextDelay() == .seconds(10))

        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(2))
    }

    @Test func corruptPendingOperationsAreQuarantinedAndRecovered() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "pending-timeline.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        let library = PendingTimelineOperationLibrary(fileURL: url)

        #expect(try await library.operations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("pending-timeline.json.corrupt-"))

        let operation = PendingTimelineOperation.delete(UUID())
        try await library.save([operation])
        #expect(try await library.operations() == [operation])
    }

    @Test func corruptCatalogIsQuarantinedAndReturnsNoSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0x00, 0x01]).write(to: url)
        let catalog = PebbleAppCatalog(cacheURL: url)

        #expect(try await catalog.cachedSnapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("catalog.json.corrupt-"))
    }

    @Test func healthLibraryMergesLargeBatchesWithoutUnboundedGrowth() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<10_000).map { index in
            PebbleHealthSample(
                date: start.addingTimeInterval(Double(index % 365) * 86_400),
                steps: index,
                sleepMinutes: index % 480
            )
        }
        let library = PebbleHealthLibrary(fileURL: url)

        let merged = try await library.merge(samples)

        #expect(merged.count <= 366)
        #expect(try await library.samples() == merged)
    }
}
