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
    private func makeModel(directory: URL) -> AppModel {
        AppModel(
            client: MockPebbleClient(),
            applicationLibrary: PebbleApplicationLibrary(
                fileURL: directory.appending(path: "applications.json")
            ),
            watchLibrary: PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        )
    }

    @Test
    func aPlaceWhoseForecastIsRefusedKeepsItsWarning() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(directory: directory)
        // Already credited, so the refresh has no reason to reach WeatherKit
        // for the attribution it must show.
        model.weatherCredit = WeatherCredit(
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
        model.weatherPlaces = [kyoto, refused]
        model.fetchWeatherReport = { place, _ in
            guard place.id == kyoto.id else { throw WeatherSourceError.placeNotFound }
            return PebbleWeatherReport(
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
        #expect(model.weatherReports.map(\.locationName) == ["Kyoto"])
        #expect(model.weatherStatusMessage != nil)
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
        let coordinator = MusicCoordinator(source: source) { frame in await log.append(frame) }
        coordinator.start()

        // A watch connects: it knows nothing, so it is sent everything.
        coordinator.watchConnected()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(await log.count == 4)

        // Nothing has changed since. A track change schedules a push whose
        // diff would be empty, and a watch connects inside that one second.
        await log.clear()
        source.onChange?()
        coordinator.watchConnected()
        try await Task.sleep(for: .milliseconds(1200))

        // The watch that just connected needs all four, not the difference
        // between two states it never saw.
        #expect(await log.count == 4)
    }

    private func healthContent(samples: [PebbleHealthSample]) -> HealthContent {
        HealthContent(
            samples: samples,
            exportURL: nil,
            statusMessage: nil,
            isWatchConnected: false,
            requestWatchSync: {},
            synchronizeWithHealthKit: {},
            importFromHealthKit: {},
            export: {},
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
            PebbleHealthSample(date: threeDaysAgo, steps: 11_240, sleepMinutes: 420),
        ])

        // A watch last worn on Friday reports Friday, and Monday must not read
        // it as this morning.
        #expect(stale.summaryDate == threeDaysAgo)
        #expect(stale.newestSample?.steps == 11_240)

        let today = healthContent(samples: [
            PebbleHealthSample(date: threeDaysAgo, steps: 11_240, sleepMinutes: 420),
            PebbleHealthSample(date: Date(), steps: 900, sleepMinutes: 0),
        ])

        #expect(today.summaryDate == nil)
        #expect(today.newestSample?.steps == 900)
    }

    @Test
    func aDayTheWatchDidNotCountIsSentTheFiguresApplyHealthHas() async throws {
        let client = MockPebbleClient()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(
            client: client,
            applicationLibrary: PebbleApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchLibrary: PebbleWatchLibrary(fileURL: directory.appending(path: "watches.json"))
        )
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 12)))
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        model.healthSamples = [
            PebbleHealthSample(
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
    var count: Int { frames.count }
    func append(_ frame: PebbleProtocolFrame) { frames.append(frame) }
    func clear() { frames = [] }
}
