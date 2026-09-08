public import Foundation
import MemberwiseInit

/// The firmware has one icon per case and nothing else, so anything outside
/// this list has to be mapped onto it.
public enum WeatherType: UInt8, Equatable, Sendable, CaseIterable {
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
    public var currentType: WeatherType
    public var todayHigh: Int16
    public var todayLow: Int16
    public var tomorrowType: WeatherType
    public var tomorrowHigh: Int16
    public var tomorrowLow: Int16
    public var shortPhrase: String
    public var updated: Date
    /// The day after tomorrow, for the timeline pins alone: the Weather DB
    /// record is version 3 and carries two days, so none of these three reach
    /// the wire. Nil where the forecast did not run that far.
    public var dayAfterTomorrowType: WeatherType? = nil
    public var dayAfterTomorrowHigh: Int16? = nil
    public var dayAfterTomorrowLow: Int16? = nil
}

public enum WeatherCodec {
    public static var databaseID: UInt8 { 5 }

    /// The firmware refuses any other version outright, so this is not a floor
    /// but an exact match.
    static let recordVersion: UInt8 = 3

    static let maximumLocationNameBytes = 63
    static let maximumShortPhraseBytes = 31

    public static func key(for report: WeatherReport) -> [UInt8] {
        BlobDBCodec.uuidBytes(report.id)
    }

    /// `WeatherDBEntry` is a packed struct: every number little-endian, nothing
    /// aligned.
    public static func value(for report: WeatherReport) -> [UInt8] {
        let name = truncated(report.locationName, toBytes: maximumLocationNameBytes)
        let phrase = truncated(report.shortPhrase, toBytes: maximumShortPhraseBytes)

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
        BlobDBCodec.insertFrame(
            databaseID: databaseID,
            key: key(for: report),
            value: value(for: report),
            token: token
        )
    }

    public static func deleteFrame(id: UUID, token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.deleteFrame(databaseID: databaseID, key: BlobDBCodec.uuidBytes(id), token: token)
    }

    public static var preferencesDatabaseID: UInt8 { 9 }

    /// The firmware compares this to the literal it holds, so it is not a UUID
    /// like the forecasts themselves.
    public static var preferencesKey: String { "weatherApp" }

    /// Writing a forecast is not enough on its own: the app walks this list and
    /// skips any forecast whose key is not in it.
    public static func preferencesValue(orderedIDs: [UUID]) -> [UInt8] {
        // `num_locations` is one byte and the firmware checks the length against it.
        let ids = orderedIDs.prefix(Int(UInt8.max))
        return [UInt8(ids.count)] + ids.flatMap { BlobDBCodec.uuidBytes($0) }
    }

    public static func preferencesFrame(orderedIDs: [UUID], token: UInt16) -> PebbleProtocolFrame {
        BlobDBCodec.insertFrame(
            databaseID: preferencesDatabaseID,
            key: Array(preferencesKey.utf8),
            value: preferencesValue(orderedIDs: orderedIDs),
            token: token
        )
    }

    private static func pascalString(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return UInt16(bytes.count).littleEndianBytes + bytes
    }

    // Counting in bytes is what matters: a name in kanji costs three a letter.
    static func truncated(_ value: String, toBytes limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        var count = 0
        for character in value {
            let size = String(character).utf8.count
            guard count + size <= limit else { break }
            result.append(character)
            count += size
        }
        return result
    }
}
