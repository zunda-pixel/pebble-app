import API
import CoreLocation
public import Foundation
import WeatherKit

/// Where a forecast is wanted: the phone's own position, or a place the reader
/// named and this app looked up once.
public struct WeatherPlace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// True for the entry that follows the phone rather than a fixed point.
    public var followsPhone: Bool

    var coordinate: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

/// What the reader must be shown alongside anything from WeatherKit: Apple's
/// mark and a link to the sources behind the data.
public struct WeatherCredit: Equatable, Sendable {
    public var serviceName: String
    public var lightMarkURL: URL
    public var darkMarkURL: URL
    public var legalPageURL: URL
}

/// Apple's weather, in the terms the watch understands.
struct WeatherBridge {
    /// Reads one place's forecast and shapes it into a record for the watch.
    ///
    /// Two days are enough: the watch shows today and tomorrow, and asking for
    /// less than the daily forecast is not possible anyway.
    func report(
        for place: WeatherPlace,
        inFahrenheit: Bool,
        now: Date = .now
    ) async throws -> PebbleWeatherReport {
        let weather = try await WeatherService.shared.weather(
            for: place.coordinate,
            including: .current, .daily
        )
        let (current, daily) = weather
        let today = daily.first { Calendar.current.isDate($0.date, inSameDayAs: now) } ?? daily.first
        let tomorrow = daily.first { day in
            guard let after = Calendar.current.date(byAdding: .day, value: 1, to: now) else {
                return false
            }
            return Calendar.current.isDate(day.date, inSameDayAs: after)
        } ?? daily.dropFirst().first

        func degrees(_ measurement: Measurement<UnitTemperature>?) -> Int16 {
            guard let measurement else { return 0 }
            let value = measurement.converted(to: inFahrenheit ? .fahrenheit : .celsius).value
            return Int16(clamping: Int(value.rounded()))
        }

        return PebbleWeatherReport(
            id: place.id,
            locationName: place.name,
            isCurrentLocation: place.followsPhone,
            currentTemperature: degrees(current.temperature),
            currentType: Self.watchType(for: current.condition, isDaylight: current.isDaylight),
            todayHigh: degrees(today?.highTemperature),
            todayLow: degrees(today?.lowTemperature),
            tomorrowType: tomorrow.map { Self.watchType(for: $0.condition, isDaylight: true) } ?? .unknown,
            tomorrowHigh: degrees(tomorrow?.highTemperature),
            tomorrowLow: degrees(tomorrow?.lowTemperature),
            shortPhrase: current.condition.description,
            updated: now
        )
    }

    func credit() async throws -> WeatherCredit {
        let attribution = try await WeatherService.shared.attribution
        return WeatherCredit(
            serviceName: attribution.serviceName,
            lightMarkURL: attribution.combinedMarkLightURL,
            darkMarkURL: attribution.combinedMarkDarkURL,
            legalPageURL: attribution.legalPageURL
        )
    }

    /// The watch has nine icons. Everything Apple reports has to land on one of
    /// them, so conditions are grouped by what they look like out of a window:
    /// how wet, how frozen, how much sky.
    static func watchType(for condition: WeatherCondition, isDaylight: Bool) -> PebbleWeatherType {
        switch condition {
        case .clear, .hot:
            isDaylight ? .sun : .partlyCloudy
        case .mostlyClear, .partlyCloudy:
            .partlyCloudy
        case .cloudy, .mostlyCloudy, .foggy, .haze, .smoky, .blowingDust, .breezy, .windy, .frigid:
            .cloudyDay
        case .drizzle, .rain, .sunShowers, .freezingDrizzle:
            .lightRain
        case .heavyRain, .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms,
             .strongStorms, .tropicalStorm, .hurricane, .freezingRain, .hail:
            .heavyRain
        case .flurries, .snow, .sunFlurries, .blizzard, .blowingSnow, .heavySnow:
            condition == .heavySnow || condition == .blizzard || condition == .blowingSnow
                ? .heavySnow
                : .lightSnow
        case .sleet, .wintryMix:
            .rainAndSnow
        @unknown default:
            .generic
        }
    }
}

/// The phone's own position, asked for once at a time.
///
/// Weather needs a rough position and nothing more, so this asks for the
/// coarse authorization the system offers and never keeps updates running.
@MainActor
@Observable
final class PhoneLocationSource: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation, any Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    var isAllowed: Bool {
        switch authorizationStatus {
        #if os(macOS)
        case .authorized, .authorizedAlways:
            true
        #else
        case .authorizedAlways, .authorizedWhenInUse:
            true
        #endif
        default:
            false
        }
    }

    func requestAuthorization() {
        #if os(macOS)
        manager.requestAlwaysAuthorization()
        #else
        manager.requestWhenInUseAuthorization()
        #endif
    }

    /// The phone's position now. Throws rather than waiting forever when the
    /// reader has not allowed it.
    func currentLocation() async throws -> CLLocation {
        guard isAllowed else { throw WeatherSourceError.locationNotAllowed }
        if let known = manager.location, known.timestamp.timeIntervalSinceNow > -900 {
            return known
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in resume(with: .success(location)) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        Task { @MainActor in resume(with: .failure(error)) }
    }

    private func resume(with result: Result<CLLocation, any Error>) {
        let continuations = waiting
        waiting = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}

enum WeatherSourceError: Error, Equatable, Sendable {
    case locationNotAllowed
    case placeNotFound
}
