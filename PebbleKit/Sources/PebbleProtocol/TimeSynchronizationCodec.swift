public import Foundation

public enum TimeSynchronizationCodec {
    public static var endpoint: UInt16 { 11 }

    public static func frame(
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> PebbleProtocolFrame {
        let roundedSeconds = date.timeIntervalSince1970.rounded()
        guard roundedSeconds >= 0, roundedSeconds <= Double(UInt32.max) else {
            throw TimeSynchronizationCodecError.dateOutOfRange
        }

        let unixTime = UInt32(roundedSeconds)
        let offsetMinutes = timeZone.secondsFromGMT(for: date) / 60
        guard let utcOffset = Int16(exactly: offsetMinutes) else {
            throw TimeSynchronizationCodecError.offsetOutOfRange
        }

        let timeZoneBytes = [UInt8](timeZone.identifier.utf8)
        guard timeZoneBytes.count <= Int(UInt8.max) else {
            throw TimeSynchronizationCodecError.timeZoneIdentifierTooLong
        }

        let offsetBits = UInt16(bitPattern: utcOffset)
        let payload: [UInt8] = [
            0x03,
            UInt8(unixTime >> 24),
            UInt8((unixTime >> 16) & 0xFF),
            UInt8((unixTime >> 8) & 0xFF),
            UInt8(unixTime & 0xFF),
            UInt8(offsetBits >> 8),
            UInt8(offsetBits & 0xFF),
            UInt8(timeZoneBytes.count),
        ] + timeZoneBytes

        return PebbleProtocolFrame(endpoint: endpoint, payload: payload)
    }
}

public enum TimeSynchronizationCodecError: Error, Equatable, Sendable {
    case dateOutOfRange
    case offsetOutOfRange
    case timeZoneIdentifierTooLong
}
