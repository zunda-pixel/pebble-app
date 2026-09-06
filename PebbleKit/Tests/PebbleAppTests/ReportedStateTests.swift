@testable import PebbleTransport
import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleApp

/// What the phone shows and sends after something has half-worked: a place
/// whose forecast did not arrive, a watch that connected mid-debounce, and a
/// watch that has not been worn today.
@Suite
@MainActor
struct ReportedStateTests {
    private func makeModel(directory: URL, client: any WatchClient = MockWatchClient()) -> AppModel {
        AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
    }

    /// A refusal the app used to swallow.
    ///
    /// Three of the switches on the watch settings screen put a refusal on the
    /// screen and the Reminders one did not, so the toggle stayed where the
    /// reader put it and the watch's Reminders app did not. Nothing anywhere
    /// said so.
    @Test
    func aRemindersAppTheWatchRefusesIsSaidOutLoud() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        // After connecting: the synchronization a connect runs writes this
        // record too, and it is the reader's own toggle that is under test.
        model.watchSettings.feedback = nil
        client.writeFailure = BlobDBClientError.rejected(.databaseFull)

        await model.setReminderAppEnabled(true)

        #expect(model.watchSettings.feedback?.isFailure == true)
        // The choice is still the reader's, and the next connection sends it
        // again: what changed is that they know it did not land.
        #expect(model.timeline.isReminderAppEnabled)
    }

    /// A place taken off the phone that the watch would not let go of.
    ///
    /// Adding one says when it fails; removing one did not, so the place left
    /// the phone's list and stayed on the wrist with nothing said about it.
    @Test
    func aPlaceTheWatchWillNotLetGoOfIsSaidOutLoud() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockWatchClient()
        let model = makeModel(directory: directory, client: client)
        await model.scan()
        let discovered = try #require(model.discoveredWatches.first)
        await model.connect(to: discovered)

        // The weather app is a capability, and the mock's watch answers without
        // one until it says otherwise.
        var capable = try #require(model.connectedWatch)
        capable.capabilities = 1 << WatchCapability.weatherApp.rawValue
        client.emit(.watchUpdated(capable))
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.connectedWatch?.supportsWeatherApp == true)

        let kyoto = WeatherPlace(
            id: UUID(),
            name: "Kyoto",
            latitude: 35.01,
            longitude: 135.76,
            followsPhone: false
        )
        model.weather.places = [kyoto]
        model.weather.feedback = nil
        client.removeFailure = BlobDBClientError.rejected(.databaseFull)

        await model.removeWeatherPlace(id: kyoto.id)

        // Gone from the phone either way — that part is the reader's decision —
        // and now the screen says the watch still has it.
        #expect(model.weather.places.isEmpty)
        #expect(model.weather.feedback?.isFailure == true)
    }

    @Test
    func aPlaceWhoseForecastIsRefusedKeepsItsWarning() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        // Already credited, so the refresh has no reason to reach WeatherKit
        // for the attribution it must show.
        model.weather.credit = WeatherCredit(
            serviceName: "Test Weather",
            lightMarkURL: URL(string: "https://example.com/light")!,
            darkMarkURL: URL(string: "https://example.com/dark")!,
            legalPageURL: URL(string: "https://example.com/legal")!
        )
        let kyoto = WeatherPlace(
            id: UUID(),
            name: "Kyoto",
            latitude: 35.01,
            longitude: 135.76,
            followsPhone: false
        )
        let refused = WeatherPlace(
            id: UUID(),
            name: "Nowhere",
            latitude: 0,
            longitude: 0,
            followsPhone: false
        )
        model.weather.places = [kyoto, refused]
        model.fetchWeatherReport = { place, _ in
            guard place.id == kyoto.id else { throw WeatherSourceError.placeNotFound }
            return WeatherReport(
                id: place.id,
                locationName: place.name,
                isCurrentLocation: false,
                currentTemperature: 21,
                currentType: .sun,
                todayHigh: 26,
                todayLow: 18,
                tomorrowType: .lightRain,
                tomorrowHigh: 24,
                tomorrowLow: 17,
                shortPhrase: "Clear",
                updated: .now
            )
        }

        await model.refreshWeather()

        // The place that worked is kept, and the one that did not keeps its
        // warning: it shows with a blank temperature and is left out of the
        // ordering the watch is given, which is not something to be quiet
        // about.
        #expect(model.weather.reports.map(\.locationName) == ["Kyoto"])
        #expect(model.weather.feedback != nil)
    }

    @Test
    func aWatchConnectingDuringTheDebounceIsStillSentEveryField() async throws {
        let source = TestMusicSource()
        source.snapshot = MusicSnapshot(
            playerPackage: "com.example.player",
            playerName: "Player",
            nowPlaying: MusicNowPlaying(artist: "Artist", album: "Album", title: "Track"),
            playback: MusicPlaybackStatus(state: .playing),
            volumePercent: 60
        )
        let log = SentFrameLog()
        // The debounce returns at once: what is under test is which fields a
        // push carries, not how long it waits before carrying them.
        let coordinator = MusicCoordinator(
            source: source,
            debounce: { _ in }
        ) { frame in await log.append(frame) }
        coordinator.start()

        // A watch connects: it knows nothing, so it is sent everything.
        coordinator.watchConnected()
        await log.reached(4)
        #expect(await log.count == 4)

        // Nothing has changed since. A track change schedules a push whose
        // diff would be empty, and a watch connects inside that window. The two
        // calls are next to each other with nothing awaited between them, and
        // the push runs on this actor, so it cannot have got in between: the
        // connect lands while the push is pending, which is the case in
        // question.
        await log.clear()
        source.onChange?()
        coordinator.watchConnected()
        await log.reached(4)

        // The watch that just connected needs all four, not the difference
        // between two states it never saw.
        #expect(await log.count == 4)
    }

    private func healthContent(samples: [WatchHealthSample]) -> HealthContent {
        HealthContent(
            samples: samples,
            exportURL: nil,
            feedback: nil,
            isWatchConnected: false,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: { nil },
            importArchive: { _ in },
            deleteLocalData: {}
        )
    }

    @Test
    func healthSummaryNamesTheDayItIsShowingWhenThatIsNotToday() async throws {
        let threeDaysAgo = try #require(
            Calendar.current.date(byAdding: .day, value: -3, to: Date())
        )
        let stale = healthContent(samples: [
            WatchHealthSample(date: threeDaysAgo, steps: 11_240, sleepMinutes: 420),
        ])

        // A watch last worn on Friday reports Friday, and Monday must not read
        // it as this morning.
        #expect(stale.summaryDate == threeDaysAgo)
        #expect(stale.newestSample?.steps == 11_240)

        let today = healthContent(samples: [
            WatchHealthSample(date: threeDaysAgo, steps: 11_240, sleepMinutes: 420),
            WatchHealthSample(date: Date(), steps: 900, sleepMinutes: 0),
        ])

        #expect(today.summaryDate == nil)
        #expect(today.newestSample?.steps == 900)
    }

    @Test
    func aDayTheWatchDidNotCountIsSentTheFiguresApplyHealthHas() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12)))
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        model.health.samples = [
            WatchHealthSample(
                date: yesterday,
                steps: 9_400,
                sleepMinutes: 430,
                deepSleepMinutes: 95,
                activeKilocalories: 512,
                restingKilocalories: 1_610,
                distanceMetres: 7_300,
                activeMinutes: 44,
                source: .healthKit
            ),
        ]

        // The watch counts steps and sleep. Energy, distance and effort come
        // from the phone or they do not come at all — sent as zero, the watch's
        // own week reads as a week spent sitting down.
        let day = try #require(model.healthDays(now: now).first)

        #expect(day.steps == 9_400)
        #expect(day.activeKilocalories == 512)
        #expect(day.restingKilocalories == 1_610)
        #expect(day.distanceMetres == 7_300)
        #expect(day.activeSeconds == 44 * 60)
        #expect(day.deepSleepSeconds == 95 * 60)
    }

    @Test
    func aDayTheWatchSyncedLastStillCarriesWhatOnlyThePhoneKnows() async throws {
        let client = MockWatchClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json"))
        )
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12)))
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        // What the merge leaves after the watch synced later than Apple Health
        // was read: one record marked `watch`, carrying figures the watch has
        // no way of counting.
        model.health.samples = [
            WatchHealthSample(
                date: yesterday,
                steps: 9_400,
                sleepMinutes: 430,
                distanceMetres: 7_300,
                source: .watch
            ),
            // A day the watch counted and nothing else touched stays with the
            // watch, which already has it.
            WatchHealthSample(
                date: try #require(Calendar.current.date(byAdding: .day, value: -2, to: now)),
                steps: 8_000,
                sleepMinutes: 400,
                source: .watch
            ),
        ]

        let days = model.healthDays(now: now)

        #expect(days.count == 1)
        #expect(days.first?.distanceMetres == 7_300)
    }
}

/// Music state a test sets by hand.
@MainActor
final class TestMusicSource: SystemMusicSource {
    var onChange: (() -> Void)?
    var snapshot: MusicSnapshot?
    func start() {}
    func stop() {}
    func perform(_ action: MusicAction) {}
}

/// What was sent to the watch. An actor because the coordinator's send handler
/// is an ordinary async function with no isolation of its own.
actor SentFrameLog {
    private var frames: [PebbleProtocolFrame] = []
    private var waiting: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var count: Int { frames.count }

    func append(_ frame: PebbleProtocolFrame) {
        frames.append(frame)
        let ready = waiting.filter { $0.target <= frames.count }
        waiting.removeAll { $0.target <= frames.count }
        for entry in ready { entry.continuation.resume() }
    }

    func clear() { frames = [] }

    /// Returns once that many frames have arrived.
    ///
    /// Woken by `append` rather than waited out on the clock: the test that
    /// reads this used to sleep 1200ms for a one-second debounce and assert
    /// what had turned up by then, which on a loaded machine was a scheduler
    /// measurement rather than a behaviour one. A push that never comes is
    /// bounded by the suite's own deadline instead.
    func reached(_ target: Int) async {
        guard frames.count < target else { return }
        await withCheckedContinuation { waiting.append((target, $0)) }
    }
}
