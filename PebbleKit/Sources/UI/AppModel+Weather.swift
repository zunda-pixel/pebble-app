import API
import CoreLocation
import Defaults
import MapKit
import Foundation
import SwiftUI

/// The weather the watch shows in its own weather app.
///
/// The phone holds the places, fetches their forecasts from WeatherKit and
/// writes one record per place into the watch's weather database. The watch
/// stores what it is given: it does no fetching and no unit conversion.
extension AppModel {
    /// Adds the phone's own position to the list, which is the entry the watch
    /// marks as current.
    public func followPhoneForWeather() async {
        guard !weatherPlaces.contains(where: \.followsPhone) else { return }
        guard phoneLocationSource.isAllowed else {
            phoneLocationSource.requestAuthorization()
            weatherStatusMessage = "Allow location access to use where the phone is."
            return
        }
        do {
            let location = try await phoneLocationSource.currentLocation()
            let name = await placeName(for: location) ?? String(localized: "Current Location")
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
            weatherStatusMessage = "The phone's position could not be read."
            await PebbleDiagnostics.shared.record(
                .error,
                category: "weather",
                message: "the phone's position: \(String(reflecting: error))"
            )
        }
    }

    /// Looks a place up by name and keeps it if it is somewhere.
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
            weatherStatusMessage = "No place was found for “\(query)”."
        }
    }

    public func removeWeatherPlace(id: UUID) async {
        weatherPlaces.removeAll { $0.id == id }
        saveWeatherPlaces()
        weatherReports.removeAll { $0.id == id }
        // The watch keeps what it was given until it is told otherwise, and
        // the app's own list has to lose the place as well.
        for connection in activeConnections where connection.device.supportsWeatherApp {
            try? await connection.client.removeWeather(id: id)
            try? await connection.client.writeWeatherLocationOrder(weatherReports.map(\.id))
        }
    }

    public func setWeatherUsesFahrenheit(_ usesFahrenheit: Bool) async {
        weatherUsesFahrenheit = usesFahrenheit
        Defaults[.weatherUsesFahrenheit] = usesFahrenheit
        await refreshWeather()
    }

    /// Fetches every place's forecast and writes it to every watch that has the
    /// weather app.
    public func refreshWeather() async {
        guard !weatherPlaces.isEmpty else {
            weatherStatusMessage = nil
            return
        }
        isRefreshingWeather = true
        defer { isRefreshingWeather = false }
        if weatherCredit == nil {
            weatherCredit = try? await weatherBridge.credit()
        }
        var reports: [PebbleWeatherReport] = []
        for place in weatherPlaces {
            var place = place
            // The entry that follows the phone is only useful where the phone
            // is now, so its position is read again before the forecast.
            if place.followsPhone, let location = try? await phoneLocationSource.currentLocation() {
                place.latitude = location.coordinate.latitude
                place.longitude = location.coordinate.longitude
            }
            do {
                reports.append(
                    try await weatherBridge.report(for: place, inFahrenheit: weatherUsesFahrenheit)
                )
            } catch {
                weatherStatusMessage = weatherFailureMessage(for: error, place: place.name)
                // `localizedDescription` on a WeatherKit failure is usually
                // "The operation couldn't be completed", which says nothing.
                // The domain and code do, so they go in the report.
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
        weatherStatusMessage = nil
        for connection in activeConnections {
            await sendWeather(to: connection)
        }
    }

    /// Writes what has already been fetched to one watch, which is what a fresh
    /// connection needs.
    func sendWeather(to connection: WatchConnection) async {
        guard connection.isConnected, !weatherReports.isEmpty else { return }
        // A watch without the weather app refuses the write, and one in
        // recovery firmware refuses everything.
        guard connection.device.supportsWeatherApp, !connection.device.isRunningRecoveryFirmware else {
            return
        }
        // The order has to be written before the forecasts: the app skips a
        // forecast whose key it has no ordering for, and this is the only place
        // that ordering comes from.
        do {
            try await connection.client.writeWeatherLocationOrder(weatherReports.map(\.id))
        } catch {
            weatherStatusMessage = "\(connection.device.name) did not accept the list of places. \(error.localizedDescription)"
            await PebbleDiagnostics.shared.record(
                .error,
                category: "weather",
                message: "\(connection.device.name) rejected the location order: \(String(reflecting: error))"
            )
            return
        }
        for report in weatherReports {
            do {
                // The write is awaited rather than posted and forgotten: the
                // watch answers every one, and a refusal — no weather app, a
                // database that is full — is the difference between "sent" and
                // "shown", which the reader is entitled to know about.
                try await connection.client.writeWeather(report)
            } catch {
                weatherStatusMessage = "\(connection.device.name) did not accept the forecast. \(error.localizedDescription)"
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "weather",
                    message: "\(connection.device.name) rejected \(report.locationName): \(String(reflecting: error))"
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

    /// The name a position reads as, so the watch shows a town rather than a
    /// pair of numbers.
    private func placeName(for location: CLLocation) async -> String? {
        let request = MKReverseGeocodingRequest(location: location)
        guard let place = try? await request?.mapItems.first else { return nil }
        return placeName(of: place)
    }

    /// A town, not a street: the watch has room for a word or two, and the
    /// place is being shown as a weather location rather than an address.
    private func placeName(of place: MKMapItem) -> String? {
        place.addressRepresentations?.cityName ?? place.name
    }
}

extension AppModel {
    /// What to say when a forecast does not arrive.
    ///
    /// WeatherKit reports the two failures a reader can do something about —
    /// an app that is not registered for the service, and a service that is
    /// out of reach — as errors of its own, and describes both as "the
    /// operation couldn't be completed". Naming them is the difference between
    /// a setting to fix and a mystery.
    func weatherFailureMessage(for error: any Error, place: String) -> LocalizedStringKey {
        let error = error as NSError
        switch error.domain {
        case NSURLErrorDomain:
            return "The forecast for \(place) could not be fetched: the network did not answer."
        case let domain where domain.contains("WeatherDaemon") || domain.contains("WeatherKit"):
            // Authentication is what fails when the app's identifier has no
            // WeatherKit capability, or the change has not propagated yet.
            return "The forecast for \(place) was refused by WeatherKit. Check that this app's identifier has the WeatherKit capability, which can take up to half an hour to take effect."
        default:
            return "The forecast for \(place) could not be fetched. \(error.localizedDescription)"
        }
    }
}
