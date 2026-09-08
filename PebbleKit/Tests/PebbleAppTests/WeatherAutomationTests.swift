import Defaults
import Foundation
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// The weather keeping itself fresh, and the three cards it puts on the
/// timeline (#95).
///
/// Serialised because the switches live in `Defaults`; the fetch itself is
/// never reached here (staleness is checked first, and these tests arrange to
/// stop there).
@Suite(.serialized)
@MainActor
struct WeatherAutomationTests {
    private func makeModel(directory: URL) -> AppModel {
        AppModel(
            client: MockWatchClient(),
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            localNotifier: SpyNotifier()
        )
    }

    private func report(id: UUID = UUID(), dayAfter: Bool = true) -> WeatherReport {
        WeatherReport(
            id: id,
            locationName: "Sapporo",
            isCurrentLocation: false,
            currentTemperature: 18,
            currentType: .partlyCloudy,
            todayHigh: 21,
            todayLow: 12,
            tomorrowType: .heavyRain,
            tomorrowHigh: 17,
            tomorrowLow: 11,
            shortPhrase: "Partly Cloudy",
            updated: Date(timeIntervalSince1970: 1_757_000_000),
            dayAfterTomorrowType: dayAfter ? .lightSnow : nil,
            dayAfterTomorrowHigh: dayAfter ? 9 : nil,
            dayAfterTomorrowLow: dayAfter ? 2 : nil
        )
    }

    /// Three pins under fixed IDs, so a refresh rewrites rather than
    /// accumulates, and yesterday's pin becomes today's instead of expiring
    /// beside it.
    @Test func theThreeDaysGetThreePinsUnderFixedIDs() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)

        let pins = AppModel.weatherPins(from: report(), now: now)
        let again = AppModel.weatherPins(from: report(id: UUID()), now: now)

        #expect(pins.count == 3)
        #expect(pins.map(\.id) == again.map(\.id))
        #expect(Set(pins.map(\.id)).count == 3)
        #expect(pins.allSatisfy { $0.parentApplicationID == AppModel.weatherDataSourceID })
        #expect(pins[0].title == "21° / 12°")
        #expect(pins[0].body == "Partly Cloudy")
        #expect(pins[1].title == "17° / 11°")
        #expect(pins[2].title == "9° / 2°")
        // Tomorrow's pin sits a day after today's.
        #expect(Calendar.current.dateComponents(
            [.day],
            from: pins[0].timestamp,
            to: pins[1].timestamp
        ).day == 1)
    }

    /// A forecast that did not run to the third day makes two pins, not a
    /// third one full of zeroes.
    @Test func aShortForecastMakesTwoPins() {
        #expect(AppModel.weatherPins(from: report(dayAfter: false)).count == 2)
    }

    /// The pins ride the same store the rest of the timeline uses, and the
    /// switch takes them out again — removal by absence, which is what the
    /// timeline sync turns into deletes on the watch.
    @Test func theSwitchPutsPinsOnTheTimelineAndTakesThemOff() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            Defaults[.weatherPinsEnabled] = false
        }
        let model = makeModel(directory: directory)
        model.weather.reports = [report()]

        Defaults[.weatherPinsEnabled] = true
        await model.updateWeatherTimelinePins()
        #expect(model.timeline.pins.filter { $0.parentApplicationID == AppModel.weatherDataSourceID }.count == 3)

        Defaults[.weatherPinsEnabled] = false
        await model.updateWeatherTimelinePins()
        #expect(model.timeline.pins.allSatisfy { $0.parentApplicationID != AppModel.weatherDataSourceID })
    }

    /// Staleness is measured from the last *successful* refresh: fresh means
    /// no fetch, stale or never-refreshed means one. The fetch itself is out of
    /// reach here, so "tried" is read off the refreshing flag's side effects —
    /// an empty place list returns before anything else, which is the arranged
    /// stop.
    @Test func theStalenessGateHoldsFreshForecastsBack() async {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            Defaults[.weatherAutoRefreshEnabled] = true
            Defaults[.weatherRefreshedAt] = nil
            Defaults[.weatherRefreshMinutes] = 60
        }
        let model = makeModel(directory: directory)
        model.weather.places = [
            WeatherPlace(id: UUID(), name: "Sapporo", latitude: 43, longitude: 141, followsPhone: false),
        ]
        Defaults[.weatherRefreshMinutes] = 60

        // Fresh: nothing to do, so no feedback and no refreshing flag ever set.
        Defaults[.weatherRefreshedAt] = Date(timeIntervalSinceNow: -10 * 60)
        await model.refreshWeatherIfStale()
        #expect(model.weather.updated == nil)

        // Off: stale or not, nothing runs.
        Defaults[.weatherAutoRefreshEnabled] = false
        Defaults[.weatherRefreshedAt] = Date(timeIntervalSinceNow: -10 * 3600)
        await model.refreshWeatherIfStale()
        #expect(model.weather.updated == nil)
    }

    /// The Weather DB switch stops the writes and only the writes.
    @Test func turningOffWatchWritesKeepsForecastsOnThePhone() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            Defaults[.weatherWritesToWatch] = true
        }
        let client = MockWatchClient()
        let model = AppModel(
            client: client,
            storageDirectory: StorageDirectory(url: directory),
            applicationLibrary: WatchApplicationLibrary(fileURL: directory.appending(path: "applications.json")),
            watchStore: SavedWatchStore(fileURL: directory.appending(path: "watches.json")),
            localNotifier: SpyNotifier()
        )
        await model.scan()
        await model.connect(to: try #require(model.discoveredWatches.first))
        let connection = try #require(model.activeConnections.first)
        // The weather app is a capability, and the mock's watch answers
        // without one until it says otherwise.
        var capable = try #require(model.connectedWatch)
        capable.version.capabilities = 1 << WatchCapability.weatherApp.rawValue
        client.emit(.watchUpdated(capable))
        try await Task.sleep(for: .milliseconds(50))
        model.weather.reports = [report()]

        Defaults[.weatherWritesToWatch] = false
        await model.sendWeather(to: connection)
        #expect(client.writtenWeather.isEmpty)

        Defaults[.weatherWritesToWatch] = true
        await model.sendWeather(to: connection)
        #expect(client.writtenWeather.count == 1)
    }
}
