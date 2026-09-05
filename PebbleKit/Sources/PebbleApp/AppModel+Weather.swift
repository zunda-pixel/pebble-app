import PebbleProtocol
import CoreLocation
import Defaults
import MapKit
public import Foundation
import SwiftUI

extension AppModel {
    public func followPhoneForWeather() async {
        guard !weatherPlaces.contains(where: \.followsPhone) else { return }
        guard phoneLocationSource.isAllowed else {
            phoneLocationSource.requestAuthorization()
            weatherFeedback = .failure("Allow location access to use where the phone is.")
            return
        }
        do {
            let location = try await phoneLocationSource.currentLocation()
            let name = await placeName(for: location) ?? String(localized: "Current Location", bundle: .module)
            weatherPlaces.insert(
                WeatherPlace(
                    id: UUID(),
                    name: name,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    followsPhone: true
                ),
                at: 0
            )
            saveWeatherPlaces()
            await refreshWeather()
        } catch {
            weatherFeedback = .failure("The phone's position could not be read.")
            await PebbleDiagnostics.shared.record(
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
            weatherPlaces.append(
                WeatherPlace(
                    id: UUID(),
                    name: placeName(of: place) ?? query,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    followsPhone: false
                )
            )
            saveWeatherPlaces()
            await refreshWeather()
        } catch {
            weatherFeedback = .failure("No place was found for “\(query)”.")
        }
    }

    public func removeWeatherPlace(id: UUID) async {
        weatherPlaces.removeAll { $0.id == id }
        saveWeatherPlaces()
        weatherReports.removeAll { $0.id == id }
        // The watch keeps what it was given until it is told otherwise.
        for connection in activeConnections where connection.watch.supportsWeatherApp {
            try? await connection.client.remove(.weather(id))
            try? await connection.client.write(.weatherOrder(weatherReports.map(\.id)))
        }
    }

    public func setWeatherUsesFahrenheit(_ usesFahrenheit: Bool) async {
        weatherUsesFahrenheit = usesFahrenheit
        Defaults[.weatherUsesFahrenheit] = usesFahrenheit
        await refreshWeather()
    }

    public func refreshWeather() async {
        guard !weatherPlaces.isEmpty else {
            weatherFeedback = nil
            return
        }
        isRefreshingWeather = true
        defer { isRefreshingWeather = false }
        if weatherCredit == nil {
            weatherCredit = try? await weatherBridge.credit()
        }
        var reports: [WeatherReport] = []
        var placeFailed = false
        for place in weatherPlaces {
            var place = place
            // The entry that follows the phone is only useful where the phone is now.
            if place.followsPhone, let location = try? await phoneLocationSource.currentLocation() {
                place.latitude = location.coordinate.latitude
                place.longitude = location.coordinate.longitude
            }
            do {
                reports.append(
                    try await fetchWeatherReport(place, weatherUsesFahrenheit)
                )
            } catch {
                placeFailed = true
                weatherFeedback = .failure(weatherFailureMessage(for: error, place: place.name))
                // `localizedDescription` on a WeatherKit failure is usually "The operation
                // couldn't be completed", which says nothing; the domain and code do.
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "weather",
                    message: "\(place.name): \(String(reflecting: error))"
                )
            }
        }
        guard !reports.isEmpty else { return }
        weatherReports = reports
        weatherUpdated = .now
        // A place whose forecast did not arrive shows a blank temperature and is
        // left out of the ordering the watch is given.
        if !placeFailed { weatherFeedback = nil }
        for connection in activeConnections {
            await sendWeather(to: connection)
        }
    }

    func sendWeather(to connection: WatchConnection) async {
        guard connection.isConnected, !weatherReports.isEmpty else { return }
        // A watch without the weather app refuses the write, and one in recovery
        // firmware refuses everything.
        guard connection.watch.supportsWeatherApp, !connection.watch.isRunningRecoveryFirmware else {
            return
        }
        // Before the forecasts: the watch skips a forecast whose key it has no
        // ordering for, and this is the only place that ordering comes from.
        do {
            try await connection.client.write(.weatherOrder(weatherReports.map(\.id)))
        } catch {
            weatherFeedback = .failure(
                "\(connection.watch.name) did not accept the list of places. \(Text(refusalReason(for: error)))"
            )
            await PebbleDiagnostics.shared.record(
                .error,
                category: "weather",
                message: "\(connection.watch.name) rejected the location order: \(String(reflecting: error))"
            )
            return
        }
        for report in weatherReports {
            do {
                // A refusal — no weather app, a database that is full — is the difference
                // between "sent" and "shown".
                try await connection.client.write(.weather(report))
            } catch {
                weatherFeedback = .failure(
                    "\(connection.watch.name) did not accept the forecast. \(Text(refusalReason(for: error)))"
                )
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "weather",
                    message: "\(connection.watch.name) rejected \(report.locationName): \(String(reflecting: error))"
                )
                return
            }
        }
    }

    func loadWeatherPlaces() {
        weatherPlaces = Defaults[.weatherPlaces]
        weatherUsesFahrenheit = Defaults[.weatherUsesFahrenheit]
    }

    private func saveWeatherPlaces() {
        Defaults[.weatherPlaces] = weatherPlaces
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
