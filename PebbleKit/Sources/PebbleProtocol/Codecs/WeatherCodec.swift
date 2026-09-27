public import Foundation
import MemberwiseInit

/// The firmware has one icon per case and nothing else, so anything outside
/// this list has to be mapped onto it.
public enum WeatherKind: UInt8, Equatable, Sendable, CaseIterable {
    case partlyCloudy = 0
    case cloudyDay = 1
    case lightSnow = 2
    case lightRain = 3
    case heavyRain = 4
    case heavySnow = 5
    case generic = 6
    case sun = 7
    case rainAndSnow = 8
    case unknown = 255
}

/// Temperatures are whole degrees in whatever unit the reader chose: the
/// record carries no unit, so the watch shows the number as it is given.
@MemberwiseInit(.public)
public struct WeatherReport: Equatable, Identifiable, Sendable {
    /// Has to stay the same across updates or the watch collects a new location
    /// every refresh.
    public var id: UUID
    public var locationName: String
    public var isCurrentLocation: Bool
    public var currentTemperature: Int16
    public var currentType: WeatherKind
    public var todayHigh: Int16
    public var todayLow: Int16
    public var tomorrowType: WeatherKind
    public var tomorrowHigh: Int16
    public var tomorrowLow: Int16
    public var shortPhrase: String
    public var updated: Date
    /// The day after tomorrow, for the timeline pins alone: the Weather DB
    /// record is version 3 and carries two days, so none of these three reach
    /// the wire. Nil where the forecast did not run that far.
    public var dayAfterTomorrowType: WeatherKind? = nil
    public var dayAfterTomorrowHigh: Int16? = nil
    public var dayAfterTomorrowLow: Int16? = nil
}

public enum WeatherCodec {
    public static var databaseID: UInt8 { 5 }

    /// Version 3 is what `weather_db.h` calls `WEATHER_DB_LEGACY_VERSION`: the
    /// firmware parses it beside the current 4 "during rollout", and refuses
    /// every other major (`weather_db_version_is_supported`). So this is an
    /// exact match rather than a floor, and one a later firmware may stop
    /// accepting.
    static let recordVersion: UInt8 = 3

    static let maximumLocationNameBytes = 63
    static let maximumShortPhraseBytes = 31

    public static func key(for report: WeatherReport) -> [UInt8] {
        report.id.bytes
    }

    /// `WeatherDBEntry` is a packed struct: every number little-endian, nothing
    /// aligned.
    public static func value(for report: WeatherReport) -> [UInt8] {
        let name = report.locationName.utf8BytesEndingOnACharacter(maximumByteCount: maximumLocationNameBytes)
        let phrase = report.shortPhrase.utf8BytesEndingOnACharacter(maximumByteCount: maximumShortPhraseBytes)

        var value: [UInt8] = [recordVersion]
        value.append(contentsOf: report.currentTemperature.littleEndianBytes)
        value.append(report.currentType.rawValue)
        value.append(contentsOf: report.todayHigh.littleEndianBytes)
        value.append(contentsOf: report.todayLow.littleEndianBytes)
        value.append(report.tomorrowType.rawValue)
        value.append(contentsOf: report.tomorrowHigh.littleEndianBytes)
        value.append(contentsOf: report.tomorrowLow.littleEndianBytes)
        value.append(contentsOf: UInt32(clamping: Int(report.updated.timeIntervalSince1970)).littleEndianBytes)
        value.append(report.isCurrentLocation ? 1 : 0)
        // A serialized array: its size in bytes, then each string as a length and
        // its bytes. The size counts the lengths too.
        let strings = pascalString(name) + pascalString(phrase)
        value.append(contentsOf: UInt16(strings.count).littleEndianBytes)
        value.append(contentsOf: strings)
        return value
    }

    public static func insertFrame(report: WeatherReport, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedInsertFrame(
            databaseID: databaseID,
            key: key(for: report),
            value: value(for: report),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.uncheckedDeleteFrame(databaseID: databaseID, key: id.bytes, token: token)
    }

    private static func pascalString(_ bytes: [UInt8]) -> [UInt8] {
        UInt16(bytes.count).littleEndianBytes + bytes
    }
}
