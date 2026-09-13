@testable import PebbleTransport
import Foundation
import HTTPTypes
import Synchronization
import Testing
import ZIPFoundation
@testable import PebbleProtocol

@Suite
@MainActor
struct LibraryAndClientTests {

    @Test func applicationLibraryPersistsUpdatesAndOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WatchApplicationLibrary(fileURL: fileURL)
        let first = WatchApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "First",
            longName: "",
            companyName: "Pebble",
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

        let reloaded = WatchApplicationLibrary(fileURL: fileURL)
        #expect(try await reloaded.applications().map(\.id) == [second.id, first.id])
        _ = try await reloaded.remove(applicationID: second.id)
        #expect(try await reloaded.applications() == [first])
    }

    @Test func applicationLibrarySnapshotRestoresMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "applications.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WatchApplicationLibrary(fileURL: fileURL)
        let application = WatchApplication(
            id: try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")),
            shortName: "Original",
            longName: "",
            companyName: "Pebble",
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
        let library = WatchApplicationLibrary(fileURL: fileURL)

        try await library.setSynchronizedApplicationIDs([firstID, secondID], watchID: WatchID("watch-a"))
        try await library.setSynchronizedApplicationIDs([secondID], watchID: WatchID("watch-b"))
        let reloaded = WatchApplicationLibrary(fileURL: fileURL)

        #expect(try await reloaded.synchronizedApplicationIDs(watchID: WatchID("watch-a")) == [firstID, secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(watchID: WatchID("watch-b")) == [secondID])
        #expect(try await reloaded.synchronizedApplicationIDs(watchID: WatchID("unknown")) == [])
    }

    @Test
    func mockClientDiscoversOnlySupportedModels() async throws {
        let client = MockWatchClient()
        let devices = try await client.scan()

        #expect(devices.count == WatchModel.allCases.count)
        #expect(Set(devices.map(\.model)) == Set(WatchModel.allCases))
    }

    @Test
    func mockClientConnectsToDiscoveredDevice() async throws {
        let client = MockWatchClient()
        let discoveredDevice = try #require(await client.scan().first)
        let connectedWatch = try await client.connect(to: discoveredDevice)

        #expect(connectedWatch.id == discoveredDevice.id)
        #expect(connectedWatch.model == discoveredDevice.model)
        #expect(connectedWatch.batteryLevel == 84)
    }

    @Test
    func mockClientRecordsAppMessagesAndResponses() async throws {
        let client = MockWatchClient()
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
        // Frames go to the log's own packet channel and nowhere near the report
        // a reader shares: fifty a second of them would be the whole of it.
        await diagnostics.recordFrame(
            direction: "out",
            frame: PebbleProtocolFrame(endpoint: 48, payload: Array("private-token".utf8))
        )
        #expect(await diagnostics.snapshot().isEmpty)
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

        let application = try #require(JSONDecoder().decode([WatchApplication].self, from: data).first)

        #expect(application.appKeys.isEmpty)
        #expect(application.hasCompanionJavaScript == false)
        #expect(application.isConfigurable == false)
    }

    @Test
    func mockClientRecordsTimelineNotifications() async throws {
        let client = MockWatchClient()
        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: "Title",
            body: "Body",
            appName: nil
        )

        try await client.write(.notification(notification))

        #expect(client.sentNotifications == [notification])
    }
}

@Suite
struct SavedWatchStoreTests {
    @Test func recordsUpdatesPreferencesAndForgetsWatches() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let fileURL = directory.appending(path: "watches.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SavedWatchStore(fileURL: fileURL)
        let device = ConnectedWatch(
            id: WatchID("watch-1"),
            name: "Pebble QEMU",
            model: .pebbleTime2,
            batteryLevel: 75,
            version: WatchVersionInformation(
                firmwareVersion: "v1",
                serialNumber: "SERIAL",
                hardwarePlatform: 18
            )
        )

        var watches = try await library.record(device)
        #expect(watches.count == 1)
        #expect(watches[0].automaticallyConnects)
        #expect(watches[0].lastBatteryLevel == 75)

        watches = try await library.setAutomaticallyConnects(false, watchID: device.id)
        #expect(!watches[0].automaticallyConnects)

        let reloaded = SavedWatchStore(fileURL: fileURL)
        #expect(try await reloaded.allWatches()[0].firmwareVersion == "v1")
        #expect(try await reloaded.remove(watchID: device.id).isEmpty)
    }

    /// A connection that does not know the hardware revision does not erase it.
    ///
    /// A watch's page shows the revision while the watch is away, the way it
    /// already shows the serial, so it has to survive a reconnection. It is
    /// kept the way the board is — and it matters more than the board, because
    /// this one comes from OTP and a watch in recovery firmware can answer the
    /// version request without it having been written.
    @Test func aRememberedHardwareRevisionOutlivesAConnectionThatDoesNotSayIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        let watchID = WatchID("watch-1")

        var watches = try await store.record(ConnectedWatch(
            id: watchID,
            name: "Pebble 5209",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v1",
                serialNumber: "SERIAL",
                hardwareRevision: "V2R2",
                hardwarePlatform: 18
            )
        ))
        #expect(watches[0].hardwareRevision == "V2R2")

        watches = try await store.record(ConnectedWatch(
            id: watchID,
            name: "Pebble 5209",
            model: .pebbleTime2,
            batteryLevel: nil,
            version: WatchVersionInformation(
                firmwareVersion: "v1",
                serialNumber: "SERIAL",
                hardwarePlatform: 18
            )
        ))
        #expect(watches[0].hardwareRevision == "V2R2")
    }

    /// A `watches.json` from before the field existed still loads.
    ///
    /// A synthesized `init(from:)` does not fall back on a property's default
    /// value, so a non-optional field added to `SavedWatch` would have refused
    /// every file already on a reader's phone — which is the whole reason
    /// `board` before it is optional too.
    @Test func aStoreWrittenBeforeTheRevisionExistedStillLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "watches.json")
        // As the store wrote it before `hardwareRevision` and `board` were
        // fields: no key for either.
        try Data("""
        [{
          "id": "watch-1",
          "name": "Pebble 5209",
          "model": "EMERY",
          "firmwareVersion": "v4.36.2",
          "serialNumber": "Q402P000000A",
          "lastConnectedAt": 780000000,
          "automaticallyConnects": true
        }]
        """.utf8).write(to: fileURL)

        let watches = try await SavedWatchStore(fileURL: fileURL).allWatches()

        #expect(watches.count == 1)
        #expect(watches[0].serialNumber == "Q402P000000A")
        #expect(watches[0].hardwareRevision == nil)
        #expect(watches[0].board == nil)
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

    @Test func aLanguagePackIsSentAsAFileNamedLang() throws {
        var session = PutBytesTransferSession(
            bytes: [1, 2, 3],
            objectType: .file,
            appBankID: 0,
            filename: PebbleLanguagePackCatalog.filename
        )
        guard case .send(let initialization) = try session.start() else {
            Issue.record("Expected a file initialization frame")
            return
        }
        // The firmware reads the name with `strlen`, so the terminator is part
        // of the message.
        #expect(initialization.payload == [
            0x01, 0, 0, 0, 3,
            PutBytesObjectType.file.rawValue, 0,
            0x6C, 0x61, 0x6E, 0x67, 0x00,
        ])

        // A named file has to be installed as well as committed, or the watch
        // keeps the bytes and never reads them.
        let actions = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 7))
        _ = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 7))
        let commit = try session.receive(PutBytesResponse(result: .acknowledgement, cookie: 7))
        #expect(!actions.isEmpty)
        #expect(commit.contains { action in
            guard case .send(let frame) = action else { return false }
            return frame.payload.first == 0x05
        })
    }

    @Test func aFilenameThatCannotBeStoredIsRefused() {
        #expect(throws: PutBytesCodecError.invalidFilename) {
            try PutBytesCodec.fileInitializationFrame(objectSize: 1, filename: "")
        }
        #expect(throws: PutBytesCodecError.invalidFilename) {
            try PutBytesCodec.fileInitializationFrame(objectSize: 1, filename: "la\0ng")
        }
    }

    @Test func languagePacksFallBackToThePebble2WhereABoardHasNoneOfItsOwn() {
        let packs = PebbleLanguagePackCatalog.packs(for: .obelixPVT)

        // Arabic is built for this board; everything else is a silk pack.
        let arabic = packs.filter { $0.locale == "ar_SA" }
        #expect(arabic.count == 1)
        #expect(arabic.first?.boardName == WatchBoard.obelixPVT.rawValue)
        #expect(packs.count > 1)
        #expect(packs.filter { $0.locale == "fr_FR" }.allSatisfy { $0.boardName == "silk" })

        // Japanese is built for no board in particular, and comes in two font
        // weights, so it must survive the board filter twice over.
        let japanese = packs.filter { $0.locale == "ja_JP" }
        #expect(japanese.count == 2)
        #expect(japanese.allSatisfy { $0.boardName == nil })
        #expect(Set(japanese.map(\.id)).count == 2)

        // A locale the board itself provides is not also offered as a fallback.
        #expect(packs.filter { $0.locale == "ar_SA" }.count == 1)
        #expect(packs.allSatisfy { $0.url.scheme == "https" })
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

    @Test func restfulSleepIsPartOfTheNightRatherThanExtraOnTopOfIt() throws {
        var processor = HealthDataLoggingProcessor()
        // Session tag 83: the watch's sleep overlays.
        let openPayload: [UInt8] = [0x01, 3] + Array(repeating: 0, count: 16)
            + [0, 0, 0, 0] + [83, 0, 0, 0] + [0, 18, 0]
        #expect(try processor.process(
            PebbleProtocolFrame(endpoint: 6_778, payload: openPayload)
        ).response?.payload == [0x85, 3])

        // Seven hours of sleep from 23:00, with two hours of restful sleep
        // inside it. The firmware records the restful stretch as a session of
        // its own whose start and end are always within the containing one
        // (`activity.h`), so the night is seven hours, not nine.
        let night = sleepItem(type: 1, start: 1_788_303_600, duration: 7 * 3600)
        let deep = sleepItem(type: 2, start: 1_788_314_400, duration: 2 * 3600)
        let sendPayload: [UInt8] = [0x02, 3] + Array(repeating: 0, count: 8) + night + deep
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: sendPayload))

        let sample = try #require(result.samples.first)
        #expect(sample.sleepMinutes == 7 * 60)
        #expect(sample.deepSleepMinutes == 2 * 60)
        #expect(sample.sleepSessions.count == 1)
    }

    @Test func aNightBrokenByAWakefulHourIsStillOneNight() {
        let midnight = Date(timeIntervalSince1970: 1_788_303_600)
        func interval(after hours: Double, lasting minutes: Double, deep: Bool = false) -> SleepInterval {
            SleepInterval(
                start: midnight.addingTimeInterval(hours * 3600),
                duration: minutes * 60,
                isDeep: deep
            )
        }

        // Turning over, and then a whole morning: an hour is the line.
        let sessions = SleepSessions.grouped([
            interval(after: 0, lasting: 180),
            interval(after: 1, lasting: 60, deep: true),
            interval(after: 3.5, lasting: 120),
            interval(after: 9, lasting: 45),
        ])

        #expect(sessions.count == 2)
        #expect(sessions[0].asleepMinutes == 300)
        #expect(sessions[0].deepMinutes == 60)
        #expect(sessions[1].asleepMinutes == 45)
    }

    @Test func anAverageIsOverTheDaysThatHadSomethingToSay() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 9)))
        func day(_ ago: Int, steps: Int, sleep: Int, deep: Int = 0) throws -> WatchHealthSample {
            WatchHealthSample(
                date: try #require(calendar.date(byAdding: .day, value: -ago, to: calendar.startOfDay(for: now))),
                steps: steps,
                sleepMinutes: sleep,
                deepSleepMinutes: deep
            )
        }
        let samples = [
            // Today is still happening, so it is left out of every average.
            try day(0, steps: 12, sleep: 12),
            try day(1, steps: 6_000, sleep: 400, deep: 100),
            try day(2, steps: 4_000, sleep: 0),
            try day(3, steps: 0, sleep: 300, deep: 60),
        ]

        let averages = samples.averages(over: 7, endingBefore: now)

        // A day the watch was off the wrist is not a day of no steps.
        #expect(averages.stepDays == 2)
        #expect(averages.steps == 5_000)
        #expect(averages.sleepDays == 2)
        #expect(averages.sleepMinutes == 350)
        #expect(averages.deepSleepMinutes == 80)
    }

    /// One sleep overlay as the watch writes it: type, the seconds east of UTC,
    /// the start and how long it lasted.
    private func sleepItem(type: UInt16, start: UInt32, duration: UInt32) -> [UInt8] {
        [0, 0, 0, 0]
            + type.littleEndianBytes
            + UInt32(0).littleEndianBytes
            + start.littleEndianBytes
            + duration.littleEndianBytes
    }

    @Test func unknownHealthDataLoggingSessionIsRejected() throws {
        var processor = HealthDataLoggingProcessor()
        let payload: [UInt8] = [0x02, 9] + Array(repeating: 0, count: 8)
        let result = try processor.process(PebbleProtocolFrame(endpoint: 6_778, payload: payload))
        #expect(result.response?.payload == [0x86, 9])
    }

    @Test func timelinePinEncodesPinTypeAndGenericLayout() throws {
        let pin = TimelinePin(
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

    @Test func aReminderGoesToItsOwnDatabaseAsItsOwnKindOfItem() throws {
        let reminder = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 0x66000000),
            title: "Tea",
            subtitle: nil,
            body: nil
        )

        let pin = try TimelinePinCodec.insertFrame(reminder, token: 1)
        let alarm = try TimelineReminderCodec.insertFrame(reminder, token: 1)

        // Pins and reminders are the same record in different databases, and
        // the type byte has to agree with the database it is filed in.
        #expect(pin.payload[3] == 0x01)
        #expect(alarm.payload[3] == 0x03)
        // Past the header and the record's own identifiers: key, value length,
        // then the item's id, its app's id, the time and the duration.
        let typeIndex = 5 + 16 + 2 + 16 + 16 + 4 + 2
        #expect(pin.payload[typeIndex] == TimelineItemType.pin.rawValue)
        #expect(alarm.payload[typeIndex] == TimelineItemType.reminder.rawValue)
    }

    @Test func aPinsTextIsCutOnACharacterAndNotInsideOne() throws {
        // Twenty-one three-byte characters, which is 63 of the 64 bytes.
        let pin = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            title: String(repeating: "石", count: 30),
            subtitle: String(repeating: "音", count: 30),
            body: nil
        )

        let attributes = Self.timelineAttributes(try pin.encoded())

        #expect(attributes.map(\.id) == [0x01, 0x02])
        #expect(attributes[0].bytes.count == 63)
        #expect(String(bytes: attributes[0].bytes, encoding: .utf8)
            == String(repeating: "石", count: 21))
        #expect(attributes[1].bytes.count == 63)
        #expect(String(bytes: attributes[1].bytes, encoding: .utf8)
            == String(repeating: "音", count: 21))
    }

    @Test func aPinIsHeldToTheFirmwaresOwnAttributeLengths() throws {
        // `MAX_ATTRIBUTE_LENGTHS`: title 64, subtitle 64, body 512.
        let pin = TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 0),
            title: String(repeating: "t", count: 200),
            subtitle: String(repeating: "s", count: 200),
            body: String(repeating: "b", count: 600)
        )

        let attributes = Self.timelineAttributes(try pin.encoded())

        #expect(attributes.map(\.id) == [0x01, 0x02, 0x03])
        #expect(attributes.map(\.bytes.count) == [64, 64, 512])
    }

    /// The attributes of an encoded timeline item, which follow a header of a
    /// fixed forty-six bytes.
    private static func timelineAttributes(_ value: [UInt8]) -> [(id: UInt8, bytes: [UInt8])] {
        var attributes: [(id: UInt8, bytes: [UInt8])] = []
        var offset = 46
        while offset + 3 <= value.count {
            let id = value[offset]
            let length = Int(value[offset + 1]) | Int(value[offset + 2]) << 8
            offset += 3
            guard offset + length <= value.count else { break }
            attributes.append((id, Array(value[offset..<(offset + length)])))
            offset += length
        }
        return attributes
    }

    @Test func healthLibraryPersistsSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "health.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WatchHealthStore(fileURL: url)
        let sample = WatchHealthSample(
            date: Date(timeIntervalSince1970: 10), steps: 1234, sleepMinutes: 420,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 20)
        )
        try await library.save([sample])
        #expect(try await library.samples() == [sample])
        let replacement = WatchHealthSample(
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
        let library = WatchHealthStore(fileURL: url)
        let watch = WatchHealthSample(
            date: Date(timeIntervalSince1970: 100), steps: 8_000, sleepMinutes: 300,
            timeZoneIdentifier: "UTC", updatedAt: Date(timeIntervalSince1970: 200)
        )
        let imported = WatchHealthSample(
            date: Date(timeIntervalSince1970: 200), steps: 7_000, sleepMinutes: 450,
            timeZoneIdentifier: "UTC", source: .imported, updatedAt: Date(timeIntervalSince1970: 300)
        )
        let merged = try await library.merge([watch, imported])
        #expect(merged.count == 1)
        #expect(merged[0].steps == 8_000)
        #expect(merged[0].sleepMinutes == 450)
        #expect(merged[0].source == .imported)
    }

    @Test func whatOnlyAppleHealthKnowsSurvivesTheWatchsOwnRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = WatchHealthStore(fileURL: directory.appending(path: "health.json"))
        let phone = WatchHealthSample(
            date: Date(timeIntervalSince1970: 100),
            steps: 7_000,
            sleepMinutes: 400,
            activeKilocalories: 420,
            restingKilocalories: 1_500,
            distanceMetres: 5_200,
            activeMinutes: 35,
            timeZoneIdentifier: "UTC",
            source: .healthKit,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        // The watch counts steps and sleep and nothing else, so its record for
        // the same day carries zeroes where the phone had readings. Taking the
        // newer record whole would throw them away.
        let watch = WatchHealthSample(
            date: Date(timeIntervalSince1970: 100),
            steps: 8_000,
            sleepMinutes: 300,
            timeZoneIdentifier: "UTC",
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = try await library.merge([phone, watch])

        #expect(merged.count == 1)
        #expect(merged[0].activeKilocalories == 420)
        #expect(merged[0].restingKilocalories == 1_500)
        #expect(merged[0].distanceMetres == 5_200)
        #expect(merged[0].activeMinutes == 35)
    }

    @Test func healthArchiveRoundTrips() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sourceURL = directory.appending(path: "source.json")
        let destinationURL = directory.appending(path: "destination.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = WatchHealthStore(fileURL: sourceURL)
        try await source.save([WatchHealthSample(date: .now, steps: 123, sleepMinutes: 45)])
        let archiveURL = try await source.export()
        let destination = WatchHealthStore(fileURL: destinationURL)
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
        let library = PendingTimelineOperationStore(fileURL: url)
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
        let application = CatalogApplication(
            id: UUID(), name: "App", developer: "Developer", version: "2.10",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        #expect(application.isNewer(than: "2.9"))
        #expect(!application.isNewer(than: "2.10"))
        #expect(!application.isNewer(than: "3.0"))
    }

    /// The address of the store's own page, and who does not get one.
    ///
    /// The identifier the official feed calls `id` is the only key the store
    /// answers to — its collections list their members by it rather than by
    /// UUID. An application with no `storeID` came from somewhere else, and
    /// offering a link to a page that is not there would be worse than
    /// offering none.
    ///
    /// The host is pinned here because the feed's own `links.share` gets it
    /// wrong: that field says `apps.rebble.io`, which serves an empty front
    /// page for anything published since it was the store. Following the
    /// feed is what this got wrong the first time.
    @Test func aCatalogApplicationLinksToItsStorePageOnlyWhenTheStoreKnowsIt() {
        func application(storeID: String?) -> CatalogApplication {
            CatalogApplication(
                id: UUID(), storeID: storeID, name: "App", developer: "Developer", version: "1.0",
                downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
            )
        }

        #expect(
            application(storeID: "1b25cef73e2b471686672d07").storePageURL
                == URL(string: "https://apps.repebble.com/1b25cef73e2b471686672d07")
        )
        // No identifier at all: a side-loaded package, or a catalogue
        // cached before this field was kept.
        #expect(application(storeID: nil).storePageURL == nil)
        // And an empty one, which the decoding boundaries never produce but
        // the memberwise initializer will accept. It percent-encodes to an
        // empty string, so without the type's own guard the link would be the
        // store's front page pretending to be one application's.
        #expect(application(storeID: "").storePageURL == nil)
        // And a legacy feed is whatever the reader pointed at, so the
        // identifier stays inside the one path segment it was given.
        #expect(
            application(storeID: "../../elsewhere").storePageURL
                == URL(string: "https://apps.repebble.com/%2E%2E%2F%2E%2E%2Felsewhere")
        )
    }

    @Test func catalogSnapshotPersistsOfflineMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "catalog.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = CatalogApplication(
            id: UUID(), name: "Cached", developer: "Developer", version: "1.0",
            downloadURL: URL(string: "https://example.com/app.pbw")!, supportedPlatforms: ["emery"]
        )
        let snapshot = CatalogSnapshot(
            sourceURL: URL(string: "https://example.com/api")!, fetchedAt: Date(timeIntervalSince1970: 100),
            applications: [application]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let catalog = AppCatalog(cacheURL: url)
        #expect(try await catalog.cachedSnapshot() == snapshot)
    }

    @Test func reconnectBackoffGrowsExponentiallyAndCaps() {
        var backoff = ReconnectBackoff(
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

    @Test func onlySomeConnectionErrorsAreWorthAnotherAttempt() {
        // Nothing the phone does within a retry's few hundred milliseconds
        // brings a lost link or a switched-off radio back.
        #expect(!WatchConnectionError.disconnected.isWorthAnotherAttempt)
        #expect(!WatchConnectionError.bluetoothUnavailable.isWorthAnotherAttempt)
        #expect(!WatchConnectionError.bluetoothUnsupported.isWorthAnotherAttempt)
        #expect(!WatchConnectionError.permissionDenied.isWorthAnotherAttempt)
        // Another attempt is exactly what has been tried.
        #expect(!WatchConnectionError.handshakeKeptFailing.isWorthAnotherAttempt)

        #expect(WatchConnectionError.connectionTimedOut.isWorthAnotherAttempt)
        #expect(WatchConnectionError.connectionFailed.isWorthAnotherAttempt)
        #expect(WatchConnectionError.protocolNegotiationFailed.isWorthAnotherAttempt)
    }

    @Test func corruptPendingOperationsAreQuarantinedAndRecovered() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = directory.appending(path: "pending-timeline.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url)
        let library = PendingTimelineOperationStore(fileURL: url)

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
        let catalog = AppCatalog(cacheURL: url)

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
            WatchHealthSample(
                date: start.addingTimeInterval(Double(index % 365) * 86_400),
                steps: index,
                sleepMinutes: index % 480
            )
        }
        let library = WatchHealthStore(fileURL: url)

        let merged = try await library.merge(samples)

        #expect(merged.count <= 366)
        #expect(try await library.samples() == merged)
    }
}

/// A stubbed HTTP server, so the network clients can be exercised without one.
///
/// Responses are keyed by URL rather than held in one slot, so cases running in
/// parallel cannot overwrite each other's setup.
final class StubURLProtocol: URLProtocol {
    struct Exchange: Sendable {
        var status: Int
        var body: Data
    }

    private struct State: Sendable {
        var exchanges: [URL: [Exchange]] = [:]
        var requestHeaders: [URL: [String: String]] = [:]
        var requestCounts: [URL: Int] = [:]
    }

    // `startLoading()` is synchronous, so the shared state is guarded rather
    // than isolated to an actor.
    private static let state = Mutex(State())

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func stub(_ url: URL, status: Int, body: Data = Data()) {
        stub(url, exchanges: [Exchange(status: status, body: body)])
    }

    /// Answers each request with the next reply in the list, so a client that
    /// retries can be shown a failure followed by a success. The last reply is
    /// repeated once the list runs out.
    static func stub(_ url: URL, exchanges: [Exchange]) {
        state.withLock {
            $0.exchanges[url] = exchanges
            $0.requestCounts[url] = 0
        }
    }

    /// The headers the client actually sent, to check what the typed request
    /// produced on the wire.
    static func sentHeaders(for url: URL) -> [String: String] {
        state.withLock { $0.requestHeaders[url] ?? [:] }
    }

    /// How many requests reached this URL, which is how a retry is observed.
    static func requestCount(for url: URL) -> Int {
        state.withLock { $0.requestCounts[url] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let headers = request.allHTTPHeaderFields ?? [:]
        let exchange = Self.state.withLock { state -> Exchange in
            state.requestHeaders[url] = headers
            let attempt = state.requestCounts[url] ?? 0
            state.requestCounts[url] = attempt + 1
            guard let exchanges = state.exchanges[url], !exchanges.isEmpty else {
                return Exchange(status: 404, body: Data())
            }
            return exchanges[min(attempt, exchanges.count - 1)]
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: exchange.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: exchange.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite
struct FirmwareCatalogNetworkTests {
    private static let releaseJSON = """
    {
      "tag_name": "v4.36.2",
      "html_url": "https://example.invalid/release",
      "assets": [
        {
          "name": "normal_obelix_pvt_v4.36.2.pbz",
          "size": 3126600,
          "browser_download_url": "https://example.invalid/normal_obelix_pvt_v4.36.2.pbz"
        }
      ]
    }
    """

    private func catalog(_ url: URL) -> PebbleOSFirmwareCatalog {
        PebbleOSFirmwareCatalog(releasesURL: url, session: StubURLProtocol.session())
    }

    @Test func aSuccessfulReplyYieldsThePackageForTheBoard() async throws {
        let url = URL(string: "https://example.invalid/successful/releases")!
        StubURLProtocol.stub(url, status: 200, body: Data(Self.releaseJSON.utf8))

        let release = try await catalog(url).latestRelease(for: .obelixPVT)

        #expect(release.versionTag == "v4.36.2")
        #expect(release.board == .obelixPVT)
        #expect(release.sizeInBytes == 3_126_600)
        // The typed header name has to survive the bridge to URLRequest.
        #expect(StubURLProtocol.sentHeaders(for: url)["Accept"] == "application/vnd.github+json")
    }

    @Test func anUnsuccessfulStatusIsReported() async {
        let url = URL(string: "https://example.invalid/unsuccessful/releases")!
        StubURLProtocol.stub(url, status: 404)

        await #expect(throws: PebbleOSFirmwareCatalogError.releasesUnavailable) {
            try await catalog(url).latestRelease(for: .obelixPVT)
        }
        // A service that has understood the request and refused it will refuse
        // it again, so nothing is gained by asking twice.
        #expect(StubURLProtocol.requestCount(for: url) == 1)
    }

    @Test func aBusyServiceIsAskedAgain() async throws {
        let url = URL(string: "https://example.invalid/busy/releases")!
        StubURLProtocol.stub(url, exchanges: [
            StubURLProtocol.Exchange(status: 503, body: Data()),
            StubURLProtocol.Exchange(status: 200, body: Data(Self.releaseJSON.utf8)),
        ])

        let release = try await catalog(url).latestRelease(for: .obelixPVT)

        #expect(release.versionTag == "v4.36.2")
        #expect(StubURLProtocol.requestCount(for: url) == 2)
    }

    @Test func aBoardWithoutAPackageIsNotAskedForTwice() async {
        let url = URL(string: "https://example.invalid/other-board-once/releases")!
        StubURLProtocol.stub(url, status: 200, body: Data(Self.releaseJSON.utf8))

        await #expect(throws: PebbleOSFirmwareCatalogError.noFirmwareForBoard(.asterix)) {
            try await catalog(url).latestRelease(for: .asterix)
        }
        // The reply arrived and was fine; the board simply has no package in it.
        #expect(StubURLProtocol.requestCount(for: url) == 1)
    }

    @Test func aBoardWithoutAPackageIsReported() async {
        let url = URL(string: "https://example.invalid/other-board/releases")!
        StubURLProtocol.stub(url, status: 200, body: Data(Self.releaseJSON.utf8))

        await #expect(throws: PebbleOSFirmwareCatalogError.noFirmwareForBoard(.asterix)) {
            try await catalog(url).latestRelease(for: .asterix)
        }
    }

    @Test func aPlainHTTPURLIsRefusedBeforeAnyRequest() async {
        // Both callers rely on this guard rather than repeating it.
        await #expect(throws: HTTPFileDownloadError.insecureURL) {
            try await downloadFile(
                from: URL(string: "http://example.invalid/firmware.pbz")!,
                using: StubURLProtocol.session()
            )
        }
    }

    @Test func anUnsuccessfulDownloadReplyIsRefused() async {
        let url = URL(string: "https://example.invalid/refused/firmware.pbz")!
        StubURLProtocol.stub(url, status: 500)

        await #expect(throws: HTTPFileDownloadError.unsuccessfulReply(.internalServerError)) {
            try await downloadFile(from: url, using: StubURLProtocol.session())
        }
    }

    @Test func onlyATransientDownloadFailureIsWorthAnotherAttempt() {
        // The status decides it: a busy or rate-limited service may answer
        // differently in a moment, one that refused the request will not.
        #expect(HTTPFileDownloadError.unsuccessfulReply(.internalServerError).isWorthAnotherAttempt)
        #expect(HTTPFileDownloadError.unsuccessfulReply(.serviceUnavailable).isWorthAnotherAttempt)
        #expect(HTTPFileDownloadError.unsuccessfulReply(.tooManyRequests).isWorthAnotherAttempt)

        #expect(!HTTPFileDownloadError.unsuccessfulReply(.notFound).isWorthAnotherAttempt)
        #expect(!HTTPFileDownloadError.unsuccessfulReply(.forbidden).isWorthAnotherAttempt)
        #expect(!HTTPFileDownloadError.insecureURL.isWorthAnotherAttempt)
        #expect(!HTTPFileDownloadError.invalidRequest.isWorthAnotherAttempt)
    }
}

/// Asking the store about one application by the identifier its package
/// carries. The way an application already installed reaches its listing,
/// since a package says nothing about which listing it came from.
@Suite
struct StoreLookupByUUIDTests {
    private static let answer = """
    {
      "data": [
        {
          "author": "Keynes",
          "category": "Tools & Utilities",
          "description": "Five watch utilities in one place.",
          "id": "1b25cef73e2b471686672d07",
          "title": "Watch Tools",
          "type": "watchapp",
          "uuid": "0b202f95-beab-4889-b7bf-949b2eff5c70",
          "hardware_platforms": [{"name": "emery"}, {"name": "basalt"}],
          "latest_release": {
            "pbw_file": "https://example.invalid/watch-tools.pbw",
            "release_notes": "Bug fixes",
            "version": "1.4.0"
          }
        }
      ],
      "limit": 1,
      "offset": 0
    }
    """

    private func catalog() -> AppCatalog {
        AppCatalog(
            cacheURL: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json"),
            session: StubURLProtocol.session()
        )
    }

    /// The answer is a list of one, which is the shape the store pages
    /// everything in, and the kind comes off the entry — this endpoint was not
    /// asked for watchapps or watchfaces, so there is nothing else to go on.
    @Test func theStoresAnswerIsUnpackedFromTheListItArrivesIn() async throws {
        let base = URL(string: "https://store.invalid/found/api")!
        let uuid = UUID(uuidString: "0B202F95-BEAB-4889-B7BF-949B2EFF5C70")!
        StubURLProtocol.stub(
            base.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased()),
            status: 200,
            body: Data(Self.answer.utf8)
        )

        let found = try #require(await catalog().application(uuid: uuid, from: base))

        #expect(found.id == uuid)
        #expect(found.storeID == "1b25cef73e2b471686672d07")
        #expect(found.name == "Watch Tools")
        #expect(found.kind == .watchapp)
        #expect(found.version == "1.4.0")
        #expect(found.category == "Tools & Utilities")
        #expect(found.supportedPlatforms.sorted() == ["basalt", "emery"])
    }

    /// An entry the store sent without a category.
    ///
    /// It decodes, and the application comes back with no category rather than
    /// with a word this app made up. `category` was a plain `String` here, so a
    /// missing key threw `keyNotFound` — and because these are decoded as an
    /// array, one uncategorised application would have failed the whole
    /// response: a by-UUID lookup would have read as an application the store
    /// does not have, and `v1/home/watchapps` would have lost all 73 of them.
    @Test func anApplicationTheStoreDidNotCategoriseStillDecodes() async throws {
        let base = URL(string: "https://store.invalid/uncategorised/api")!
        let uuid = UUID()
        let answer = """
        {
          "data": [
            {
              "author": "Keynes",
              "description": "Five watch utilities in one place.",
              "id": "1b25cef73e2b471686672d07",
              "title": "Watch Tools",
              "type": "watchapp",
              "uuid": "\(uuid.uuidString.lowercased())",
              "hardware_platforms": [{"name": "emery"}],
              "latest_release": {
                "pbw_file": "https://example.invalid/watch-tools.pbw",
                "version": "1.4.0"
              }
            }
          ],
          "limit": 1,
          "offset": 0
        }
        """
        StubURLProtocol.stub(
            base.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased()),
            status: 200,
            body: Data(answer.utf8)
        )

        let found = try #require(await catalog().application(uuid: uuid, from: base))

        #expect(found.name == "Watch Tools")
        #expect(found.category == nil)
        // The entry does carry a description, so the summary is still there:
        // this test is about the one missing field, not about all of them.
        #expect(found.summary == "Five watch utilities in one place.")
    }

    /// An empty string is the same answer as no answer.
    ///
    /// The store sends `"category": ""` as readily as it omits the key. It is
    /// settled here, at the boundary, so that no screen has to write
    /// `if let category, !category.isEmpty` — an optional and a sentinel
    /// checked one after the other for one question, which is what three of
    /// them were doing.
    @Test func aFieldTheStoreSentEmptyReadsAsAbsent() async throws {
        let base = URL(string: "https://store.invalid/blank/api")!
        let uuid = UUID()
        let answer = """
        {
          "data": [
            {
              "author": "Keynes",
              "category": "",
              "description": "",
              "id": "1b25cef73e2b471686672d07",
              "title": "Watch Tools",
              "type": "watchapp",
              "uuid": "\(uuid.uuidString.lowercased())",
              "hardware_platforms": [{"name": "emery"}],
              "latest_release": {
                "pbw_file": "https://example.invalid/watch-tools.pbw",
                "release_notes": "",
                "version": "1.4.0"
              }
            }
          ],
          "limit": 1,
          "offset": 0
        }
        """
        StubURLProtocol.stub(
            base.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased()),
            status: 200,
            body: Data(answer.utf8)
        )

        let found = try #require(await catalog().application(uuid: uuid, from: base))

        #expect(found.category == nil)
        #expect(found.summary == nil)
    }

    /// One unusable entry costs that entry, not the response it came in.
    ///
    /// `application(kind:)` was already written to skip an entry with no UUID
    /// or an unusable download — but the fields it checked were plain `String`s
    /// on the wire type above it, so a *missing* key threw `keyNotFound` before
    /// the guard could run. These decode inside an array, so one pulled release
    /// in `v1/home/watchapps` took all 73 of the day's featured applications
    /// with it, and the guard meant to handle it never ran.
    @Test func oneUnusableEntryDoesNotCostTheWholeResponse() async throws {
        let base = URL(string: "https://store.invalid/partial/api")!
        let uuid = UUID()
        let answer = """
        {
          "data": [
            { "id": "no-release", "title": "Gone", "author": "Keynes", "type": "watchapp",
              "uuid": "\(UUID().uuidString.lowercased())", "latest_release": {} },
            { "id": "no-title", "author": "Keynes", "type": "watchapp",
              "uuid": "\(UUID().uuidString.lowercased())",
              "latest_release": {"pbw_file": "https://example.invalid/a.pbw", "version": "1.0"} },
            { "id": "no-type", "title": "Untyped", "author": "Keynes",
              "uuid": "\(UUID().uuidString.lowercased())",
              "latest_release": {"pbw_file": "https://example.invalid/b.pbw", "version": "1.0"} },
            { "id": "1b25cef73e2b471686672d07", "title": "Watch Tools", "author": "Keynes",
              "type": "watchapp", "uuid": "\(uuid.uuidString.lowercased())",
              "hardware_platforms": [{"name": "emery"}, {}],
              "latest_release": {"pbw_file": "https://example.invalid/watch-tools.pbw", "version": "1.4.0"} }
          ],
          "limit": 4,
          "offset": 0
        }
        """
        StubURLProtocol.stub(
            base.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased()),
            status: 200,
            body: Data(answer.utf8)
        )

        // The lookup takes the entry's own word for its kind, so the untyped
        // one is skipped too — and the good one at the end still arrives.
        let found = try #require(await catalog().application(uuid: uuid, from: base))

        #expect(found.name == "Watch Tools")
        #expect(found.storeID == "1b25cef73e2b471686672d07")
        // A platform entry with no name is dropped rather than taken as one.
        #expect(found.supportedPlatforms == ["emery"])
    }

    /// Not an error. Plenty of packages were never listed, and a reader who
    /// installed one from a file should see the screen without a complaint on
    /// it.
    @Test func anApplicationTheStoreDoesNotHaveIsAnAnswerRatherThanAFailure() async throws {
        let base = URL(string: "https://store.invalid/missing/api")!
        let uuid = UUID()
        StubURLProtocol.stub(
            base.appending(path: "v1/apps/uuid").appending(path: uuid.uuidString.lowercased()),
            status: 404
        )

        #expect(try await catalog().application(uuid: uuid, from: base) == nil)
    }
}
