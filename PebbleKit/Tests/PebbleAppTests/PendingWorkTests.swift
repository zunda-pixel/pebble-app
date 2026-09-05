import Foundation
import Testing
import ZIPFoundation
@testable import PebbleProtocol
@testable import PebbleTransport
@testable import PebbleApp

/// Work the phone holds on a watch's behalf: notifications and messages queued
/// while it was away, timeline changes waiting to be written, and an import
/// whose transfer the watch refused.
@Suite(.serialized)
@MainActor
struct PendingWorkTests {
    private func makeModel(client: any PebbleClient, directory: URL) -> AppModel {
        AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    @Test
    func twoOverlappingFlushesDeliverEachQueuedNotificationOnce() async throws {
        let client = SuspendingPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        try await model.pendingNotificationStore.save([])

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        let queued = (0..<3).map { index in
            PebbleTimelineNotification(
                parentApplicationID: UUID(),
                title: "Queued \(index)",
                body: "While the watch was away",
                appName: "Chat"
            )
        }
        model.pendingNotifications = queued.map { PendingDelivery(work: $0) }

        // Both callers ask at once, which is what happens when the app comes
        // forward while a watch is finishing its reconnection.
        async let first: Void = model.flushPendingNotifications()
        async let second: Void = model.flushPendingNotifications()
        _ = await (first, second)

        // Each flush working from its own snapshot made the watch buzz twice
        // for every queued notification.
        #expect(client.sentNotifications.map(\.id) == queued.map(\.id))
        #expect(model.pendingNotifications.isEmpty)
    }

    @Test
    func aNotificationTheSecondWatchRefusesIsNotShownTwiceOnTheFirst() async throws {
        var clients: [WatchID: SuspendingPebbleClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: MockPebbleClient(),
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { watchID in
                let client = SuspendingPebbleClient()
                clients[watchID] = client
                return client
            }
        )
        try await model.pendingNotificationStore.save([])
        await model.scan()
        let devices = model.discoveredWatches
        let first = try #require(devices.first)
        let second = try #require(devices.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)
        let refusing = try #require(clients[second.id])
        refusing.notificationFailure = PebbleConnectionError.disconnected

        let notification = PebbleTimelineNotification(
            parentApplicationID: UUID(),
            title: "Queued",
            body: "One watch took it",
            appName: "Chat"
        )
        model.pendingNotifications = [PendingDelivery(work: notification)]
        await model.flushPendingNotifications()
        // The second watch comes back, and the first is asked for nothing.
        refusing.notificationFailure = nil
        await model.flushPendingNotifications()

        // The watch that took it first used to be shown it again every time the
        // other one refused: two notifications, two buzzes, one message.
        #expect(clients[first.id]?.sentNotifications.map(\PebbleTimelineNotification.id) == [notification.id])
        #expect(refusing.sentNotifications.map(\.id) == [notification.id])
        #expect(model.pendingNotifications.isEmpty)
    }

    @Test
    func twoOverlappingFlushesSendEveryQueuedAppMessage() async throws {
        let client = SuspendingPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        try await model.pendingAppMessageStore.save([])

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        let queued = [
            StoredAppMessage(applicationID: UUID(), tuples: []),
            StoredAppMessage(applicationID: UUID(), tuples: []),
        ]
        model.pendingAppMessages = queued

        async let first: Void = model.flushPendingAppMessages()
        async let second: Void = model.flushPendingAppMessages()
        _ = await (first, second)

        // Removing whatever was first at the time dropped the second message
        // without ever sending it, and then saved the empty queue.
        #expect(client.sentAppMessages.map { $0.applicationID } == queued.map(\.applicationID))
        #expect(model.pendingAppMessages.isEmpty)
    }

    @Test
    func aPinTheAppNoLongerHasIsTakenOffTheWatch() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        let pin = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3600),
            title: "Dentist",
            subtitle: nil,
            body: nil
        )
        try await model.timelineStore.save([pin])
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        await model.synchronizeTimeline()
        #expect(client.timelinePins.map(\.id) == [pin.id])

        // The pin goes from under the app: a queue that was lost, or an app that
        // was reinstalled and never knew about it.
        try await model.timelineStore.save([])
        try await model.pendingTimelineOperationStore.save([])
        await model.synchronizeTimeline()

        // Nothing else can name it: BlobDB has no listing, and no delete was
        // ever queued for it.
        #expect(client.timelinePins.isEmpty)
        #expect(try await model.timelineStore.writtenPinIDs(watchID: discovered.id).isEmpty)

        try await model.timelineStore.forgetWrittenPinIDs(watchID: discovered.id)
    }

    @Test
    func aPinTheWatchMadeIsKeptAndNotSentBackToIt() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        // What the watch hands over after someone dictates a reminder to it: a
        // record of its own pin database, on the endpoint it starts itself.
        let dictated = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3600),
            title: "牛乳を買う",
            subtitle: nil,
            body: nil,
            isFromWatch: true
        )
        let connection = try #require(model.activeConnections.first)
        await model.handleWatchDatabaseWrite(
            offer(dictated, database: TimelinePinCodec.databaseID),
            on: connection
        )

        #expect(model.timelinePins.map(\.id) == [dictated.id])
        #expect(model.timelinePins.first?.isFromWatch == true)
        // Every offer is answered, and this one was taken.
        #expect(client.sentFrames.last?.payload == [0x88, 0x0C, 0x00, 0x01])

        await model.synchronizeTimeline()

        // The watch's own copy has actions and an icon this app does not model,
        // so writing this back would replace it with less than it already has.
        #expect(client.timelinePins.isEmpty)

        try await model.timelineStore.forgetWrittenPinIDs(watchID: discovered.id)
    }

    /// The frame a watch sends to hand over a record of a database of its own.
    @Test
    func aReminderTheWatchPostponedReplacesTheOneItSentBefore() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        let connection = try #require(model.activeConnections.first)
        // Whole seconds: the wire carries a `time_t`, so a date with a
        // fraction in it does not come back the same.
        let dictated = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 3600).rounded()),
            title: "会議",
            subtitle: nil,
            body: nil,
            kind: .reminder,
            isFromWatch: true
        )
        await model.handleWatchDatabaseWrite(
            offer(dictated, database: TimelineReminderCodec.databaseID),
            on: connection
        )

        // Postponed on the watch: the same item, at a later hour, offered
        // again under the id it already had.
        var postponed = dictated
        postponed.timestamp = dictated.timestamp.addingTimeInterval(1800)
        await model.handleWatchDatabaseWrite(
            offer(postponed, database: TimelineReminderCodec.databaseID),
            on: connection
        )

        #expect(model.reminders.map(\.id) == [dictated.id])
        #expect(model.reminders.first?.timestamp == postponed.timestamp)
    }

    @Test
    func aDictatedReminderDeletedWhileTheWatchWasAwayIsTakenOffIt() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let dictated = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3600),
            title: "会議",
            subtitle: nil,
            body: nil,
            kind: .reminder,
            isFromWatch: true
        )
        await model.handleWatchDatabaseWrite(
            offer(dictated, database: TimelineReminderCodec.databaseID),
            on: try #require(model.activeConnections.first)
        )
        #expect(model.reminders.map(\.id) == [dictated.id])

        await model.disconnect()
        await model.removeReminders(model.reminders)
        await model.connect(to: discovered)

        // This app never wrote it — the watch made it — so only a record of
        // what the watch holds can name it once it is gone from here.
        #expect(client.deletedTimelineReminderIDs.contains(dictated.id))
    }

    private func offer(
        _ item: PebbleTimelinePin,
        database: UInt8,
        token: [UInt8] = [0x0C, 0x00]
    ) -> PebbleProtocolFrame {
        let value = (try? item.encoded()) ?? []
        var payload: [UInt8] = [0x08] + token + [database, 0x00, 0x00, 0x00, 0x00, 16]
        payload += Array(repeating: 0, count: 16)
        payload += [UInt8(value.count & 0xFF), UInt8(value.count >> 8)]
        payload += value
        return PebbleProtocolFrame(endpoint: BlobDB2Codec.endpoint, payload: payload)
    }

    @Test
    func clearingTheWatchsTimelineWritesBackWhatTheAppHas() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        let pin = PebbleTimelinePin(
            parentApplicationID: UUID(),
            timestamp: .now.addingTimeInterval(3600),
            title: "Kept",
            subtitle: nil,
            body: nil
        )
        try await model.timelineStore.save([pin])
        try await model.pendingTimelineOperationStore.save([])
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        await model.clearWatchTimeline(watchID: discovered.id)

        // The reader asked for this because the watch held pins nothing could
        // name; their own are not collateral.
        #expect(client.clearedTimelineCount == 1)
        #expect(client.timelinePins.map(\.id) == [pin.id])

        try await model.timelineStore.save([])
        try await model.timelineStore.forgetWrittenPinIDs(watchID: discovered.id)
    }

    @Test
    func aFullTimelineQueueGivesUpUpsertsRatherThanDeletes() async throws {
        let client = SuspendingPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)

        // A calendar synchronization queues its deletes first and then one
        // upsert per pin, which is how the deletes came to be the oldest
        // entries and so the first ones evicted.
        let removedEventID = UUID()
        var operations: [PendingTimelineOperation] = [.delete(removedEventID)]
        operations += (0..<205).map { index -> PendingTimelineOperation in
            .upsert(PebbleTimelinePin(
                parentApplicationID: UUID(),
                timestamp: Date(),
                title: "Event \(index)",
                subtitle: nil,
                body: nil
            ))
        }

        model.trimQueuedOperations(&operations)

        #expect(operations.count == 200)
        // A dropped upsert comes back: `synchronizeTimeline` derives one for
        // every pin the phone holds. A dropped delete never would, and the
        // event would stay on the watch for good.
        #expect(operations.contains(.delete(removedEventID)))
        #expect(model.dataSyncStatusMessage == nil)
    }

    @Test
    func deletesAreKeptPastTheCapAndSaidOutLoud() async throws {
        let client = SuspendingPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)

        var operations: [PendingTimelineOperation] = (0..<210).map { _ -> PendingTimelineOperation in
            .delete(UUID())
        }
        model.trimQueuedOperations(&operations)

        // Nothing here can be reconstructed, so nothing is thrown away — and
        // the reader is told the watch is behind rather than left to find out.
        #expect(operations.count == 210)
        #expect(model.dataSyncStatusMessage != nil)
    }

    @Test
    func aTransferTheWatchRefusesPutsTheEarlierVersionBack() async throws {
        let client = SuspendingPebbleClient()
        client.transferFailure = PutBytesTransferError.negativeAcknowledgement
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(
            client: client,
            applicationLibrary: library,
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let connection = try #require(model.connections.first)

        // Version 1 is what the reader has; version 2 has just been imported
        // over the top of it. The library entry and the stored package are
        // both version 2 now, and the snapshot is the only copy of version 1.
        let applicationID = UUID()
        let firstVersion = try makeApplicationPackage(
            in: directory,
            applicationID: applicationID,
            versionLabel: "1.0"
        )
        let secondVersion = try makeApplicationPackage(
            in: directory,
            applicationID: applicationID,
            versionLabel: "2.0"
        )
        _ = try await library.importPackage(from: firstVersion)
        let snapshot = try await library.snapshot(applicationID: applicationID)
        model.updateApplications(try await library.importPackage(from: secondVersion))
        model.pendingImportSnapshots[applicationID] = snapshot

        await model.handleAppFetchRequest(
            AppFetchRequest(applicationID: applicationID, appBankID: 0),
            from: connection
        )

        let storedVersions = try await library.applications().map(\.versionLabel)
        let storedPackage = try #require(await library.storedPackageURL(applicationID: applicationID))
        let storedBytes = try Data(contentsOf: storedPackage)
        let firstVersionBytes = try Data(contentsOf: firstVersion)

        // Version 1 is back, in the library and on disk, which is what the
        // message shown for a refused transfer has always claimed.
        #expect(storedVersions == ["1.0"])
        #expect(model.watchApplications.map(\.versionLabel) == ["1.0"])
        #expect(storedBytes == firstVersionBytes)
        #expect(model.pendingImportSnapshots.isEmpty)
        #expect(model.applicationLibraryErrorMessage != nil)
        #expect(client.appFetchResponses.contains(.noData))
    }

    /// A `.pbw` holding one application built for the Pebble Time 2, which is
    /// the watch these tests connect to.
    private func makeApplicationPackage(
        in directory: URL,
        applicationID: UUID,
        versionLabel: String
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
          "shortName": "Orbit",
          "longName": "Orbit",
          "companyName": "Pebble",
          "versionLabel": "\(versionLabel)",
          "targetPlatforms": ["emery"],
          "watchapp": { "watchface": false }
        }
        """.utf8))

        // The executable carries the identifier the importer checks the
        // package against, so its header has to name this application.
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
