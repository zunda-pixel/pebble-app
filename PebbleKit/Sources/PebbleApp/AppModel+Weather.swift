import PebbleProtocol
import CoreLocation
import Defaults
import MapKit
public import Foundation
import SwiftUI

extension AppModel {
    public func followPhoneForWeather() async {
        guard !weather.places.contains(where: \.followsPhone) else { return }
        guard phoneLocationSource.isAllowed else {
            phoneLocationSource.requestAuthorization()
            weather.feedback = .failure("Allow location access to use where the phone is.")
            return
        }
        do {
            // The position is read here for the *name* alone; the row keeps no
            // coordinates, so a later refresh can never fall back to today's.
            let location = try await phoneLocationSource.currentLocation()
            let name = await placeName(for: location) ?? String(localized: "Current Location", bundle: .module)
            weather.places.insert(
                WeatherPlace(id: UUID(), name: name, position: .phone),
                at: 0
            )
            saveWeatherPlaces()
            await refreshWeather()
        } catch {
            weather.feedback = .failure("The phone's position could not be read.")
            await DiagnosticLog.shared.record(
                .error,
                category: "weather",
                message: "the phone's position: \(String(reflecting: error))"
            )
        }
    }

    public func addWeatherPlace(named query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        do {
            guard let request = MKGeocodingRequest(addressString: query) else {
                throw WeatherSourceError.placeNotFound
            }
            guard let place = try await request.mapItems.first else {
                throw WeatherSourceError.placeNotFound
            }
            let coordinate = place.location.coordinate
            weather.places.append(
                WeatherPlace(
                    id: UUID(),
                    name: placeName(of: place) ?? query,
                    position: .fixed(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                )
            )
            saveWeatherPlaces()
            await refreshWeather()
        } catch {
            weather.feedback = .failure("No place was found for “\(query)”.")
        }
    }

    public func removeWeatherPlace(id: UUID) async {
        // Named before it goes, for the failure that says which place is still
        // on the watch.
        let name = weather.places.first { $0.id == id }?.name ?? ""
        weather.places.removeAll { $0.id == id }
        saveWeatherPlaces()
        weather.reports.removeAll { $0.id == id }
        // The watch keeps what it was given until it is told otherwise — and
        // until this said so, a refusal here left the place on the watch with
        // nothing said about it anywhere: gone from the phone, still on the
        // wrist, and no way to tell why.
        for connection in activeConnections where connection.watch.supportsWeatherApp {
            do {
                try await connection.client.remove(.weather(id))
            } catch {
                weather.feedback = .failure(
                    "\(connection.watch.name) still has \(name). \(Text(refusalReason(for: error)))"
                )
                continue
            }
            do {
                try await connection.client.write(.weatherOrder(weather.reports.map(\.id)))
            } catch {
                weather.feedback = .failure(
                    "\(connection.watch.name) did not accept the list of places. \(Text(refusalReason(for: error)))"
                )
            }
        }
    }

    public func setWeatherUsesFahrenheit(_ usesFahrenheit: Bool) async {
        weather.usesFahrenheit = usesFahrenheit
        Defaults[.weatherUsesFahrenheit] = usesFahrenheit
        await refreshWeather()
    }

    public func refreshWeather() async {
        // A caller who asked outright — a pull, a changed unit — is owed a
        // round that saw their change, so a round already in flight is waited
        // out rather than joined. The stale-gated callers join instead, in
        // `refreshWeatherIfStale`; they are the ones that race.
        while let running = weather.refreshTask {
            await running.value
        }
        // The task clears its own handle before finishing: awaiting a finished
        // task need not suspend, so a waiter waking to a handle the claimant
        // had not cleared yet would spin on the main actor without ever
        // letting the claimant back on to clear it.
        let task = Task {
            await self.runWeatherRefresh()
            self.weather.refreshTask = nil
        }
        weather.refreshTask = task
        await task.value
    }

    private func runWeatherRefresh() async {
        guard !weather.places.isEmpty else {
            weather.feedback = nil
            return
        }
        weather.isRefreshing = true
        defer { weather.isRefreshing = false }
        if weather.credit == nil {
            weather.credit = try? await weatherBridge.credit()
        }
        var reports: [WeatherReport] = []
        var placeFailed = false
        for place in weather.places {
            let location: CLLocation
            switch place.position {
            case .fixed(let latitude, let longitude):
                location = CLLocation(latitude: latitude, longitude: longitude)
            case .phone:
                // A position the phone will not give is a failure to say, not
                // a fallback to take: the coordinates this used to fall back
                // on were a snapshot from the day the row was added, served
                // under the name "Current Location" (#122).
                do {
                    location = try await phoneLocationSource.currentLocation()
                } catch {
                    placeFailed = true
                    weather.feedback = .failure("The phone's position could not be read.")
                    await DiagnosticLog.shared.record(
                        .error,
                        category: "weather",
                        message: "the phone's position: \(String(reflecting: error))"
                    )
                    continue
                }
            }
            do {
                reports.append(
                    try await fetchWeatherReport(place, location, weather.usesFahrenheit)
                )
            } catch {
                placeFailed = true
                weather.feedback = .failure(weatherFailureMessage(for: error, place: place.name))
                // `localizedDescription` on a WeatherKit failure is usually "The operation
                // couldn't be completed", which says nothing; the domain and code do.
                await DiagnosticLog.shared.record(
                    .error,
                    category: "weather",
                    message: "\(place.name): \(String(reflecting: error))"
                )
            }
        }
        guard !reports.isEmpty else { return }
        weather.reports = reports
        weather.updated = .now
        // Only a round with every place answered counts as "refreshed": a
        // partial one leaves the clock alone, so the next opportunity retries.
        if !placeFailed {
            weather.feedback = nil
            Defaults[.weatherRefreshedAt] = .now
        }
        for connection in activeConnections {
            await sendWeather(to: connection)
        }
        await updateWeatherTimelinePins()
    }

    func sendWeather(to connection: WatchConnection) async {
        // The reader said the watch's weather app is not this app's to feed.
        // The timeline pins have their own switch and their own path.
        guard Defaults[.weatherWritesToWatch] else { return }
        guard connection.isConnected, !weather.reports.isEmpty else { return }
        // A watch without the weather app refuses the write, and one in recovery
        // firmware refuses everything.
        guard connection.watch.supportsWeatherApp, !connection.watch.isRunningRecoveryFirmware else {
            return
        }
        // Before the forecasts: the watch skips a forecast whose key it has no
        // ordering for, and this is the only place that ordering comes from.
        do {
            try await connection.client.write(.weatherOrder(weather.reports.map(\.id)))
        } catch {
            weather.feedback = .failure(
                "\(connection.watch.name) did not accept the list of places. \(Text(refusalReason(for: error)))"
            )
            await DiagnosticLog.shared.record(
                .error,
                category: "weather",
                message: "\(connection.watch.name) rejected the location order: \(String(reflecting: error))"
            )
            return
        }
        for report in weather.reports {
            do {
                // A refusal — no weather app, a database that is full — is the difference
                // between "sent" and "shown".
                try await connection.client.write(.weather(report))
            } catch {
                weather.feedback = .failure(
                    "\(connection.watch.name) did not accept the forecast. \(Text(refusalReason(for: error)))"
                )
                await DiagnosticLog.shared.record(
                    .error,
                    category: "weather",
                    message: "\(connection.watch.name) rejected \(report.locationName): \(String(reflecting: error))"
                )
                return
            }
        }
        // Said out loud because a refusal is the only other thing recorded here,
        // and silence alone cannot tell "the watch took it" from "nothing ran".
        await DiagnosticLog.shared.record(
            category: "weather",
            message: "\(connection.watch.name) took \(weather.reports.count) forecast(s) and their order"
        )
    }

    func loadWeatherPlaces() {
        weather.places = Defaults[.weatherPlaces]
        weather.usesFahrenheit = Defaults[.weatherUsesFahrenheit]
    }

    private func saveWeatherPlaces() {
        Defaults[.weatherPlaces] = weather.places
    }

    private func placeName(for location: CLLocation) async -> String? {
        let request = MKReverseGeocodingRequest(location: location)
        guard let place = try? await request?.mapItems.first else { return nil }
        return placeName(of: place)
    }

    // A town, not a street: the watch has room for a word or two.
    private func placeName(of place: MKMapItem) -> String? {
        place.addressRepresentations?.cityName ?? place.name
    }
}

extension AppModel {
    func weatherFailureMessage(for error: any Error, place: String) -> LocalizedStringKey {
        let error = error as NSError
        switch error.domain {
        case NSURLErrorDomain:
            return "The forecast for \(place) could not be fetched: the network did not answer."
        case let domain where domain.contains("WeatherDaemon") || domain.contains("WeatherKit"):
            return "The forecast for \(place) was refused by WeatherKit. Check that this app's identifier has the WeatherKit capability, which can take up to half an hour to take effect."
        default:
            return "The forecast for \(place) could not be fetched. \(error.localizedDescription)"
        }
    }
}

extension AppModel {
    /// The watch's weather app and its timeline pins share this identity:
    /// `UUID_WEATHER_DATA_SOURCE` in PebbleOS's `timeline.h`, the UUID the
    /// firmware's own weather app registers under.
    static let weatherDataSourceID = UUID(uuidString: "61B22BC8-1E29-460D-A236-3FE409A439FF")!

    /// Refreshes if the forecast has gone stale, and quietly does nothing
    /// otherwise. This is what the connect path and the foreground loop call:
    /// neither promises a time, only that a forecast older than the chosen
    /// interval is renewed at the next opportunity the OS gives the app.
    ///
    /// Staleness is measured from the last *successful* refresh, so a failure
    /// makes the very next opportunity a retry rather than waiting a whole
    /// interval to notice.
    func refreshWeatherIfStale(now: Date = .now) async {
        guard Defaults[.weatherAutoRefreshEnabled], !weather.places.isEmpty else { return }
        // The staleness clock only moves when a round finishes, so two of
        // these racing — the foreground handler and a fresh connection — both
        // read "stale" while the first round is still in flight. WeatherKit is
        // a per-watch quota, and a second round would also write every watch
        // its forecasts twice; the round under way is this caller's answer.
        if let running = weather.refreshTask {
            await running.value
            return
        }
        if let refreshed = Defaults[.weatherRefreshedAt],
           now.timeIntervalSince(refreshed) < Double(Defaults[.weatherRefreshMinutes]) * 60 {
            return
        }
        await refreshWeather()
    }

    /// The three cards the weather puts on the timeline: today, tomorrow and
    /// the day after, from the first place in the reader's own ordering.
    ///
    /// The IDs are fixed — the weather source UUID with the last byte swapped
    /// for the day index — so a refresh rewrites the same three pins instead
    /// of growing a trail, and yesterday's pin *becomes* today's rather than
    /// expiring beside it. Rewriting and removal both ride the existing
    /// timeline machinery, reconnect queue included.
    static func weatherPins(from report: WeatherReport, now: Date = .now) -> [TimelinePin] {
        func pinID(day: Int) -> UUID {
            var bytes = weatherDataSourceID.uuid
            bytes.15 = UInt8(day)
            return UUID(uuid: bytes)
        }
        func pin(day: Int, high: Int16, low: Int16, phrase: String?) -> TimelinePin? {
            guard high != WeatherBridge.unknownTemperature, low != WeatherBridge.unknownTemperature else { return nil }
            let calendar = Calendar.current
            guard let date = calendar.date(byAdding: .day, value: day, to: now),
                  // Where the watch files a day's card: the morning of it. A
                  // midnight pin sorts before "last night" on the timeline.
                  let start = calendar.date(
                      bySettingHour: 6, minute: 0, second: 0, of: calendar.startOfDay(for: date)
                  ) else { return nil }
            return TimelinePin(
                id: pinID(day: day),
                parentApplicationID: weatherDataSourceID,
                timestamp: start,
                title: "\(high)° / \(low)°",
                subtitle: report.locationName,
                body: phrase
            )
        }
        var pins = [
            pin(day: 0, high: report.todayHigh, low: report.todayLow, phrase: report.shortPhrase),
            pin(day: 1, high: report.tomorrowHigh, low: report.tomorrowLow, phrase: nil),
        ]
        if let high = report.dayAfterTomorrowHigh, let low = report.dayAfterTomorrowLow {
            pins.append(pin(day: 2, high: high, low: low, phrase: nil))
        }
        return pins.compactMap { $0 }
    }

    /// Puts the weather's pins on the timeline, or takes them off it, to match
    /// the switch and the newest forecast. Removal is by absence: the timeline
    /// sync deletes from the watch whatever the store no longer holds.
    func updateWeatherTimelinePins() async {
        let others = timeline.pins.filter { $0.parentApplicationID != Self.weatherDataSourceID }
        let weatherPins: [TimelinePin] = if Defaults[.weatherPinsEnabled],
            let primary = weather.reports.first {
            Self.weatherPins(from: primary)
        } else {
            []
        }
        let changed = others + weatherPins
        guard changed != timeline.pins else { return }
        timeline.pins = changed
        try? await timelineStore.save(timeline.pins)
        await synchronizeTimeline()
    }

    public func setWeatherAutoRefresh(enabled: Bool) async {
        Defaults[.weatherAutoRefreshEnabled] = enabled
        if enabled { await refreshWeatherIfStale() }
    }

    public func setWeatherRefreshMinutes(_ minutes: Int) async {
        Defaults[.weatherRefreshMinutes] = minutes
        await refreshWeatherIfStale()
    }

    public func setWeatherWritesToWatch(_ enabled: Bool) async {
        Defaults[.weatherWritesToWatch] = enabled
        guard enabled else { return }
        for connection in activeConnections {
            await sendWeather(to: connection)
        }
    }

    public func setWeatherPinsEnabled(_ enabled: Bool) async {
        Defaults[.weatherPinsEnabled] = enabled
        await updateWeatherTimelinePins()
    }
}
