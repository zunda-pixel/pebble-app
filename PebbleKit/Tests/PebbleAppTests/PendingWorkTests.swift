import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport
@testable import PebbleApp

/// Work the phone holds on a watch's behalf: notifications and messages queued
/// while it was away, timeline changes waiting to be written, and an import
/// whose transfer the watch refused.
@Suite(.serialized)
@MainActor
struct PendingWorkTests {
    private func makeModel(client: any WatchClient, directory: URL) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    @Test
    func twoOverlappingFlushesDeliverEachQueuedNotificationOnce() async throws {
        let client = SuspendingWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        try await model.pendingNotificationStore.save([])

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        let queued = (0..<3).map { index in
            TimelineNotification(
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

    /// The digest record moves by what was actually sent, not to a snapshot of
    /// the pin list. Snapshot bookkeeping recorded pins a pass never wrote and
    /// resurrected entries the reconciliation had just cleaned, so every
    /// queued trigger "forgot" and re-removed the same pins (#123) — and a
    /// pass that died part-way recorded none of what it did manage, so the
    /// next one re-sent pins the watch already held.
    @Test
    func aPartialSendKeepsExactlyWhatGotThrough() async throws {
        let client = SuspendingWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let pins = ["A", "B", "C"].map { title in
            TimelinePin(parentApplicationID: UUID(), timestamp: .now, title: title, subtitle: nil, body: nil)
        }
        try await model.timelineStore.save(pins)
        try await model.pendingTimelineOperationStore.save([])
        // The link dies after two pins, the way a watch walking away does.
        client.timelinePinWritesAllowed = 2

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))

        let watchID = try #require(model.connectedWatch?.id)
        let afterFailure = try await model.timelineStore.writtenPinDigests(watchID: watchID)
        #expect(Set(afterFailure.keys) == Set(pins.prefix(2).map(\.id)))

        // The link recovers: only the pin that never got through is sent, and
        // nothing is "forgotten" and re-removed.
        client.timelinePinWritesAllowed = nil
        await model.synchronizeTimeline()

        #expect(client.timelinePinWrites == pins.map(\.id))
        #expect(client.deletedPinIDs.isEmpty)

        // And a third pass has nothing left to say.
        await model.synchronizeTimeline()
        #expect(client.timelinePinWrites == pins.map(\.id))
    }

    @Test
    func aNotificationTheSecondWatchRefusesIsNotShownTwiceOnTheFirst() async throws {
        var clients: [WatchID: SuspendingWatchClient] = [:]
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { watchID in
                let client = SuspendingWatchClient()
                clients[watchID] = client
                return client
            }
        )
        try await model.pendingNotificationStore.save([])
        await model.scan()
        let watches = model.discoveredWatches
        let first = try #require(watches.first)
        let second = try #require(watches.dropFirst().first)
        await model.connect(to: first)
        await model.connect(to: second)
        let refusing = try #require(clients[second.id])
        refusing.notificationFailure = WatchConnectionError.disconnected

        let notification = TimelineNotification(
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
        #expect(clients[first.id]?.sentNotifications.map(\TimelineNotification.id) == [notification.id])
        #expect(refusing.sentNotifications.map(\.id) == [notification.id])
        #expect(model.pendingNotifications.isEmpty)
    }

    @Test
    func twoOverlappingFlushesSendEveryQueuedAppMessage() async throws {
        let client = SuspendingWatchClient()
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        let pin = TimelinePin(
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
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
        let dictated = TimelinePin(
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

        #expect(model.timeline.pins.map(\.id) == [dictated.id])
        #expect(model.timeline.pins.first?.isFromWatch == true)
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
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
        let dictated = TimelinePin(
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

        #expect(model.timeline.reminders.map(\.id) == [dictated.id])
        #expect(model.timeline.reminders.first?.timestamp == postponed.timestamp)
    }

    @Test
    func aDictatedReminderDeletedWhileTheWatchWasAwayIsTakenOffIt() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            reminderStore: TimelinePinStore(fileURL: directory.appending(path: "reminders.json")),
            clientFactory: { _ in client }
        )
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let dictated = TimelinePin(
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
        #expect(model.timeline.reminders.map(\.id) == [dictated.id])

        await model.disconnect()
        await model.removeReminders(model.timeline.reminders)
        await model.connect(to: discovered)

        // This app never wrote it — the watch made it — so only a record of
        // what the watch holds can name it once it is gone from here.
        #expect(client.deletedTimelineReminderIDs.contains(dictated.id))
    }

    private func offer(
        _ item: TimelinePin,
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
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        let pin = TimelinePin(
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

        let afterConnecting = client.timelinePinWrites.count

        await model.clearWatchTimeline(watchID: discovered.id)

        // The reader asked for this because the watch held pins nothing could
        // name; their own are not collateral.
        #expect(client.clearedTimelineCount == 1)
        #expect(client.timelinePins.map(\.id) == [pin.id])
        // Written again rather than skipped: clearing forgets the digests with
        // the identifiers, or the write-back would send nothing to a watch whose
        // database is now empty.
        #expect(client.timelinePinWrites.count == afterConnecting + 1)

        try await model.timelineStore.save([])
        try await model.timelineStore.forgetWrittenPinIDs(watchID: discovered.id)
    }

    private func timelinePin(_ title: String, minutesFromNow: Double) -> TimelinePin {
        TimelinePin(
            parentApplicationID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + minutesFromNow * 60),
            title: title,
            subtitle: nil,
            body: nil
        )
    }

    /// `synchronizeTimeline` derives an upsert for every pin the app holds, and
    /// derived them all every time: on the reader's watch that was 74, then 92,
    /// then 93 pins in 47 seconds, re-writing the same bytes to the same keys.
    /// The app glances have always compared what they last sent; the pins now
    /// do too, from a digest kept per watch.
    @Test
    func aPinTheWatchAlreadyHasIsNotWrittenAgain() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let pins = [timelinePin("Dentist", minutesFromNow: 60), timelinePin("Standup", minutesFromNow: 120)]
        try await model.timelineStore.save(pins)
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        await model.synchronizeTimeline()
        #expect(Set(client.timelinePinWrites) == Set(pins.map(\.id)))
        let afterFirst = client.timelinePinWrites.count

        // Nothing has changed here and nothing has changed there.
        await model.synchronizeTimeline()
        await model.synchronizeTimeline()

        #expect(client.timelinePinWrites.count == afterFirst)
    }

    @Test
    func onlyThePinThatChangedIsWrittenAgain() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        var pins = [timelinePin("Dentist", minutesFromNow: 60), timelinePin("Standup", minutesFromNow: 120)]
        try await model.timelineStore.save(pins)
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        await model.synchronizeTimeline()
        let afterFirst = client.timelinePinWrites.count

        // Retitled, so the bytes the watch holds are no longer the bytes here.
        pins[1].title = "Standup, moved"
        try await model.timelineStore.save(pins)
        await model.synchronizeTimeline()

        #expect(client.timelinePinWrites.count == afterFirst + 1)
        #expect(client.timelinePinWrites.last == pins[1].id)
        #expect(client.timelinePins.first { $0.id == pins[1].id }?.title == "Standup, moved")
    }

    /// A second watch has been given nothing, whatever the first one holds.
    @Test
    func eachWatchIsMeasuredAgainstWhatItWasGiven() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            clientFactory: { _ in client }
        )
        let pins = [timelinePin("Dentist", minutesFromNow: 60), timelinePin("Standup", minutesFromNow: 120)]
        try await model.timelineStore.save(pins)
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        let discovered = model.discoveredWatches
        await model.connect(to: try #require(discovered.first))
        await model.synchronizeTimeline()
        let afterFirst = client.timelinePinWrites.count

        await model.connect(to: try #require(discovered.dropFirst().first))
        await model.synchronizeTimeline()

        // Both pins again, for the watch that has not seen them.
        #expect(client.timelinePinWrites.count == afterFirst + pins.count)
    }

    /// What a watch is sent again after its protocol session was started over on
    /// a live link.
    ///
    /// The transport used to drop the whole link when the watch asked for a new
    /// session, which cost a reconnect and the bond check with it. Now the link
    /// stays and the app hears the same pair of events a reconnect gives it: what
    /// it holds only per connection is thrown away and sent again, and what the
    /// watch holds in its own databases is left where it is. A restart that
    /// forgot the pin digests too would re-write every pin the watch already had,
    /// which is the cost this pair of changes exists to remove.
    @Test
    func aSessionStartedOverLeavesTheWatchsOwnRecordsAlone() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let pins = [timelinePin("Dentist", minutesFromNow: 60), timelinePin("Standup", minutesFromNow: 120)]
        try await model.timelineStore.save(pins)
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let connection = try #require(model.connections.first)
        let application = UUID()
        model.applications.installedIDsByWatch[connection.watch.id] = [application]
        await model.setAppGlance(AppGlance(
            applicationID: application,
            slices: [AppGlanceSlice(subtitleTemplate: "Kyoto 18°")]
        ))
        await model.synchronizeAppGlances(on: connection)
        await model.synchronizeTimeline()
        #expect(client.appGlanceWrites == [application])
        let pinsBefore = client.timelinePinWrites.count
        // Taken before: a connection in the middle of a restart is not connected,
        // so the app has no watch to name until the watch has answered again.
        let watch = try #require(model.connectedWatch)

        // The pair the transport sends: the session has gone, and then the watch
        // has answered on the new one.
        client.emit(.reconnecting(watchID: discovered.id))
        await Task.yield()
        client.emit(.watchUpdated(watch))
        try await Task.sleep(for: .milliseconds(200))

        #expect(model.connectionState == .connected(watch))
        // What the app was holding about this watch went with the session, so a
        // glance is sent again as soon as the app knows the watch has the app to
        // put it on — which `aLauncherLineGoesOnlyToAWatchThatHasTheApp` covers.
        #expect(connection.synchronizedAppGlances.isEmpty)
        // The watch's timeline database did not go with the session, so its pins
        // are left alone.
        #expect(client.timelinePinWrites.count == pinsBefore)
    }

    /// Letting go of a pin takes it off the watch once.
    ///
    /// It went twice: `removeTimelinePins` queues a delete, and the
    /// reconciliation that runs first sees the same pin missing from what the
    /// app holds and takes it off too. The second remove came back
    /// `keyDoesNotExist`, which is accepted, so nothing failed — every deletion
    /// simply cost a round trip it did not need. The reader's log showed both:
    /// `removed 1 of 1 pin(s) the app no longer has`, then `dropped 1`.
    @Test
    func aPinLetGoOfIsTakenOffTheWatchOnce() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let kept = timelinePin("Standup", minutesFromNow: 60)
        let going = timelinePin("Dentist", minutesFromNow: 120)
        try await model.timelineStore.save([kept, going])
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        await model.synchronizeTimeline()
        #expect(client.timelinePinWrites.count == 2)
        #expect(client.timelinePinRemovals.isEmpty)

        // The reader deletes one, which queues a delete and leaves the pin out
        // of what the app holds — so both mechanisms have it in their sights.
        await model.removeTimelinePins([going])

        #expect(client.timelinePinRemovals == [going.id])
        #expect(client.timelinePins.map(\.id) == [kept.id])
        // And the one that stayed was not written again on the way past.
        #expect(client.timelinePinWrites.count == 2)
    }

    /// Two pins under one identifier is not a state anything downstream can
    /// represent, so the timeline does not hold one.
    ///
    /// BlobDB is keyed by the identifier, so the watch keeps whichever arrived
    /// last; the record of what was written keeps one digest per key, so the
    /// others never match it and are sent again on every synchronization. The
    /// reader's watch was written 32 pins of 94 that way, every time, for ever.
    @Test
    func pinsSharingAnIdentifierAreCollapsedToTheLastOfThem() throws {
        var first = timelinePin("Standup", minutesFromNow: 60)
        let other = timelinePin("Dentist", minutesFromNow: 120)
        var second = first
        second.title = "Standup, moved"
        first.title = "Standup"

        let kept = AppModel.pinsUnderOneIdentifierEach([first, other, second])

        // One entry per identifier, in the order they first appeared, and the
        // last of each — which is what the watch and the digests end up with.
        #expect(kept.map(\.id) == [first.id, other.id])
        #expect(kept.first?.title == "Standup, moved")
        // Nothing to do when they are already distinct.
        #expect(AppModel.pinsUnderOneIdentifierEach([first, other]).count == 2)
        #expect(AppModel.pinsUnderOneIdentifierEach([]).isEmpty)
    }

    @Test
    func aTimelineLoadedWithDuplicatesSettlesAfterOnePass() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let pin = timelinePin("Standup", minutesFromNow: 60)
        var twin = pin
        twin.title = "Standup, moved"
        // What a shared calendar identifier left on disk.
        try await model.timelineStore.save([pin, twin])
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        await model.synchronizeTimeline()
        #expect(model.timeline.pins.count == 1)
        let afterFirst = client.timelinePinWrites.count

        await model.synchronizeTimeline()

        // Sent once and then left alone, rather than for ever.
        #expect(client.timelinePinWrites.count == afterFirst)
    }

    /// Every occurrence of a recurring event is its own pin.
    ///
    /// They shared one, because `EKEvent.eventIdentifier` is one per event and
    /// was the whole of the key. On the reader's watch that was 32 of 94 pins
    /// sent on every synchronization — the digest kept under the shared key
    /// could only match one of them — and, worse, a weekly meeting appeared on
    /// the watch once, because the occurrences overwrote each other in a BlobDB
    /// keyed by the same id.
    @Test
    func eachOccurrenceOfARecurringEventIsItsOwnPin() {
        let weekly = "weekly-standup"
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(7 * 24 * 60 * 60)

        let keys = [first, second].map {
            CalendarBridge.occurrenceKey(identity: weekly, occurrence: $0)
        }

        #expect(keys[0] != keys[1])
        // And the same occurrence read twice is the same pin, or it would be
        // written again on every synchronization.
        #expect(CalendarBridge.occurrenceKey(identity: weekly, occurrence: first) == keys[0])
        // Two events at the same moment are still two events.
        #expect(CalendarBridge.occurrenceKey(identity: "dentist", occurrence: first) != keys[0])
    }

    /// A calendar read that changed nothing queues nothing.
    ///
    /// Queueing every pin put them all past the digest comparison, because the
    /// queue is a change and `synchronizeTimeline` does not second-guess it: on
    /// the reader's watch that was 32 unchanged pins written again after one
    /// disconnect, and once more for every `EKEventStoreChanged`.
    @Test
    func onlyTheCalendarPinsThatChangedAreWorthQueueing() throws {
        let unchanged = timelinePin("Standup", minutesFromNow: 60)
        var edited = timelinePin("Dentist", minutesFromNow: 120)
        let before = [unchanged, edited]

        // Retitled where it stands, which is what an edited event looks like:
        // the identifier comes from the event and does not move.
        edited.title = "Dentist, moved"
        let added = timelinePin("Lunch", minutesFromNow: 180)

        let worth = AppModel.calendarPinsWorthQueueing([unchanged, edited, added], replacing: before)

        #expect(worth.map(\.id) == [edited.id, added.id])
    }

    /// The pin the comparison skipped is not lost: a watch that never got it is
    /// sent it from the digests instead, which is the other half of the pair.
    @Test
    func aCalendarPinNotWorthQueueingIsStillSentToAWatchWithoutIt() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let pin = timelinePin("Standup", minutesFromNow: 60)
        try await model.timelineStore.save([pin])
        // Nothing queued, the way a calendar read that changed nothing leaves it.
        try await model.pendingTimelineOperationStore.save([])

        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        await model.synchronizeTimeline()

        #expect(client.timelinePinWrites == [pin.id])
    }

    @Test
    func aFullTimelineQueueGivesUpUpsertsRatherThanDeletes() async throws {
        let client = SuspendingWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)

        // A calendar synchronization queues its deletes first and then one
        // upsert per pin, which is how the deletes came to be the oldest
        // entries and so the first ones evicted.
        let removedEventID = UUID()
        var operations: [PendingTimelineOperation] = [.delete(removedEventID)]
        operations += (0..<205).map { index -> PendingTimelineOperation in
            .upsert(TimelinePin(
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
        #expect(model.timeline.feedback == nil)
    }

    @Test
    func deletesAreKeptPastTheCapAndSaidOutLoud() async throws {
        let client = SuspendingWatchClient()
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
        // On the Timeline screen, which is where the reader asked. It used to be
        // written to the property the Health and Catalog screens read (#60).
        #expect(model.timeline.feedback?.isFailure == true)
    }

    @Test
    func aTransferTheWatchRefusesPutsTheEarlierVersionBack() async throws {
        let client = SuspendingWatchClient()
        client.transferFailure = PutBytesTransferError.negativeAcknowledgement
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
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
        #expect(model.applications.apps.map(\.versionLabel) == ["1.0"])
        #expect(storedBytes == firstVersionBytes)
        #expect(model.pendingImportSnapshots.isEmpty)
        #expect(model.applications.libraryFeedback != nil)
        #expect(client.appFetchResponses.contains(.noData))
    }

    @Test
    func aFetchCancelledByAReconnectDoesNotEndTheOneThatReplacedIt() async throws {
        let client = SuspendingWatchClient()
        client.answerDelay = .milliseconds(300)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json"))
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: library,
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let applicationID = UUID()
        let package = try makeApplicationPackage(in: directory, applicationID: applicationID, versionLabel: "1.0")
        model.updateApplications(try await library.importPackage(from: package))
        let connection = WatchConnection(
            client: client,
            watch: ConnectedWatch(
                id: WatchID("suspending-emery"),
                name: "Pebble Time 2",
                model: .pebbleTime2,
                batteryLevel: 70,
                version: WatchVersionInformation(
                    firmwareVersion: "v5.0.0-test",
                    serialNumber: "TEST00000001",
                    hardwarePlatform: 18
                )
            )
        )
        let request = AppFetchRequest(applicationID: applicationID, appBankID: 0)

        model.beginHandlingAppFetchRequest(request, from: connection)
        let cancelled = try #require(connection.appFetchTask)
        model.clearBusyOperationState(on: connection)
        model.beginHandlingAppFetchRequest(request, from: connection)
        await cancelled.value

        #expect(connection.isFetchingApplication)
        #expect(model.applications.managementOperation == .installing(applicationID))

        await connection.appFetchTask?.value
        #expect(!connection.isFetchingApplication)
        #expect(model.applications.managementOperation == nil)
    }

    @Test
    func comingForwardDoesNotRewindTheQueueToTheCopyOnDisk() async throws {
        let client = SuspendingWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        model.hasStarted = true
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let notification = TimelineNotification(
            parentApplicationID: UUID(),
            title: "Already delivered",
            body: "Before the save caught up",
            appName: "Chat"
        )
        // Delivered in memory; the disk still has it owed, the way it stands
        // between a delivery and the save at the end of the pass.
        model.pendingNotifications = [PendingDelivery(work: notification, deliveredTo: [discovered.id])]
        try await model.pendingNotificationStore.save([PendingDelivery(work: notification)])

        await model.applicationDidBecomeActive()

        #expect(client.sentNotifications.isEmpty)
    }

    @Test
    func aWatchDroppingLeavesAnotherWatchsOperationRunning() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        let dropped = WatchConnection(
            client: client,
            watch: ConnectedWatch(
                id: WatchID("dropped"),
                name: "Pebble Time 2",
                model: .pebbleTime2,
                batteryLevel: 50,
                version: WatchVersionInformation(
                    firmwareVersion: "v5.0.0-test",
                    serialNumber: "TEST00000002",
                    hardwarePlatform: 18
                )
            )
        )
        model.applications.managementOperation = .reordering

        model.clearBusyOperationState(on: dropped)

        #expect(model.applications.managementOperation == .reordering)
    }

    @Test
    func aMessageTheWatchRefusesDoesNotHoldBackAnotherAppsMessages() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let notRunning = StoredAppMessage(applicationID: UUID(), tuples: [])
        let running = StoredAppMessage(applicationID: UUID(), tuples: [])
        client.appsRefusingMessages = [notRunning.applicationID]
        model.pendingAppMessages = [notRunning, running]

        await model.flushPendingAppMessages()

        #expect(client.sentAppMessages.map(\.applicationID) == [running.applicationID])
        #expect(model.pendingAppMessages == [notRunning])
    }

    @Test
    func aScriptsMessageWithNoWatchToTakeItIsQueuedAndReportedAsNotSent() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)

        await #expect(throws: WatchConnectionError.disconnected) {
            try await model.sendOrQueueAppMessage(applicationID: UUID(), tuples: [])
        }

        #expect(model.pendingAppMessages.count == 1)
    }

    @Test
    func aMessageOlderThanADayIsDroppedRatherThanDelivered() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        model.pendingAppMessages = [
            StoredAppMessage(applicationID: UUID(), tuples: [], createdAt: Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)),
        ]

        await model.flushPendingAppMessages()

        #expect(client.sentAppMessages.isEmpty)
        #expect(model.pendingAppMessages.isEmpty)
    }

    @Test
    func forgettingAWatchDropsTheFirmwareUpdateStagedForIt() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(client: client, directory: directory)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)
        let journal = FirmwareUpdateJournal(
            watchID: discovered.id,
            board: .obelixPVT,
            previousVersion: nil,
            targetVersion: nil,
            packageFileName: "staged.pbz",
            packageSHA256: "0000"
        )
        try await model.pendingFirmwareUpdateStore.save(journal)
        model.firmware[discovered.id].journal = journal

        #expect(await model.forgetWatch(id: discovered.id))

        #expect(try await model.pendingFirmwareUpdateStore.journal(for: discovered.id) == nil)
        #expect(model.firmware[discovered.id].journal == nil)
    }
}
