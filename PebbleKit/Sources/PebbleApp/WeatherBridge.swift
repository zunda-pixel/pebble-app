import PebbleProtocol
import CoreLocation
public import Foundation
import WeatherKit

/// Where a place's forecast is fetched for.
///
/// Two variants rather than coordinates plus a flag: the phone-following row
/// used to persist a snapshot of wherever the phone was when it was added, and
/// a failed location read silently served that stale place under the name
/// "Current Location" (#122). A `.phone` row holds no coordinates to fall back
/// on, so the failure has to be said instead.
public enum WeatherPlacePosition: Codable, Equatable, Hashable, Sendable {
    /// Wherever the phone is at the moment the forecast is fetched.
    case phone
    case fixed(latitude: Double, longitude: Double)
}

public struct WeatherPlace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var position: WeatherPlacePosition

    public init(id: UUID, name: String, position: WeatherPlacePosition) {
        self.id = id
        self.name = name
        self.position = position
    }

    public var followsPhone: Bool {
        position == .phone
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, position
        // The shape this was stored as before positions existed.
        case latitude, longitude, followsPhone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let position = try container.decodeIfPresent(WeatherPlacePosition.self, forKey: .position) {
            self.position = position
        } else if try container.decodeIfPresent(Bool.self, forKey: .followsPhone) == true {
            // The legacy snapshot coordinates are dropped on purpose: they are
            // wherever the phone was the day the row was added, which is the
            // stale fallback this type exists to end.
            position = .phone
        } else {
            position = .fixed(
                latitude: try container.decode(Double.self, forKey: .latitude),
                longitude: try container.decode(Double.self, forKey: .longitude)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(position, forKey: .position)
    }
}

/// Apple requires the mark and a link to the sources be shown alongside
/// anything from WeatherKit.
public struct WeatherCredit: Equatable, Sendable {
    public var serviceName: String
    public var lightMarkURL: URL
    public var darkMarkURL: URL
    public var legalPageURL: URL
}

struct WeatherBridge {
    /// What the watch draws as "--°" rather than as a temperature
    /// (`WEATHER_SERVICE_LOCATION_FORECAST_UNKNOWN_TEMP`,
    /// `apps/system/weather/weather_types.h`; `prv_fill_high_low_buffer` in
    /// `weather_app_layout.c`). A missing forecast sent as zero is drawn as a
    /// real 0°.
    static let unknownTemperature: Int16 = 32_767

    /// `location` is resolved by the caller: for a `.fixed` place it is the
    /// stored pair, and for `.phone` it is a fresh read whose failure the
    /// caller reports rather than papering over.
    func report(
        for place: WeatherPlace,
        at location: CLLocation,
        inFahrenheit: Bool,
        now: Date = .now
    ) async throws -> WeatherReport {
        // Two days are enough for what the watch shows, and asking for less
        // than the daily forecast is not something WeatherKit offers.
        let weather = try await WeatherService.shared.weather(
            for: location,
            including: .current, .daily
        )
        let (current, daily) = weather
        func day(offset: Int) -> DayWeather? {
            guard let target = Calendar.current.date(byAdding: .day, value: offset, to: now) else {
                return nil
            }
            return daily.first { Calendar.current.isDate($0.date, inSameDayAs: target) }
        }
        let today = day(offset: 0) ?? daily.first
        let tomorrow = day(offset: 1) ?? daily.dropFirst().first
        // For the timeline pins alone; the watch's own record carries two days.
        let dayAfter = day(offset: 2)

        func degrees(_ measurement: Measurement<UnitTemperature>?) -> Int16 {
            guard let measurement else { return Self.unknownTemperature }
            let value = measurement.converted(to: inFahrenheit ? .fahrenheit : .celsius).value
            return Int16(clamping: Int(value.rounded()))
        }

        return WeatherReport(
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
            updated: now,
            dayAfterTomorrowType: dayAfter.map { Self.watchType(for: $0.condition, isDaylight: true) },
            dayAfterTomorrowHigh: dayAfter.map { degrees($0.highTemperature) },
            dayAfterTomorrowLow: dayAfter.map { degrees($0.lowTemperature) }
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

    // The watch has nine icons, so conditions are grouped by what they look like
    // out of a window: how wet, how frozen, how violent.
    static func watchType(for condition: WeatherCondition, isDaylight: Bool) -> WeatherKind {
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

/// Weather needs a rough position and nothing more, so this asks for a fix
/// to the kilometre. That makes the fix cheaper, not the permission smaller:
/// the authorization asked for is the ordinary one, and whether it is precise
/// is the reader's choice in the system's dialog.
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
