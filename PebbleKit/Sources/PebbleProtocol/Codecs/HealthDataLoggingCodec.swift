import Foundation
import MemberwiseInit

@MemberwiseInit(.public)
public struct HealthDataLoggingResult: Equatable, Sendable {
    public var response: PebbleProtocolFrame? = nil
    public var samples: [WatchHealthSample] = []
}

public struct HealthDataLoggingProcessor: Sendable {
    private var sessions: [UInt8: Session] = [:]

    public init() {}

    public mutating func process(_ frame: PebbleProtocolFrame) throws -> HealthDataLoggingResult {
        guard frame.endpoint == HealthDataLoggingCodec.endpoint, let command = frame.payload.first else {
            throw HealthDataLoggingError.invalidPayload
        }
        switch command {
        case 0x01:
            guard frame.payload.count >= 29 else { throw HealthDataLoggingError.invalidPayload }
            let sessionID = frame.payload[1]
            let tag = try uint32(frame.payload, at: 22)
            let itemSize = Int(try uint16(frame.payload, at: 27))
            sessions[sessionID] = Session(tag: tag, itemSize: itemSize)
            return HealthDataLoggingResult(response: HealthDataLoggingCodec.ackFrame(sessionID: sessionID))
        case 0x02:
            guard frame.payload.count >= 10 else { throw HealthDataLoggingError.invalidPayload }
            let sessionID = frame.payload[1]
            guard let session = sessions[sessionID] else {
                return HealthDataLoggingResult(response: HealthDataLoggingCodec.nackFrame(sessionID: sessionID))
            }
            let payload = Array(frame.payload.dropFirst(10))
            return HealthDataLoggingResult(
                response: HealthDataLoggingCodec.ackFrame(sessionID: sessionID),
                samples: try samples(from: payload, session: session)
            )
        case 0x03, 0x07:
            guard frame.payload.count >= 2 else { throw HealthDataLoggingError.invalidPayload }
            let sessionID = frame.payload[1]
            sessions.removeValue(forKey: sessionID)
            return HealthDataLoggingResult(response: HealthDataLoggingCodec.ackFrame(sessionID: sessionID))
        default:
            return HealthDataLoggingResult()
        }
    }

    private func samples(from bytes: [UInt8], session: Session) throws -> [WatchHealthSample] {
        guard session.itemSize > 0 else { throw HealthDataLoggingError.invalidItemSize }
        switch session.tag {
        case 81, 85:
            return try stepSamples(from: bytes, itemSize: session.itemSize)
        case 83, 84:
            return try sleepSamples(from: bytes, itemSize: session.itemSize)
        default:
            return []
        }
    }

    private func stepSamples(from bytes: [UInt8], itemSize: Int) throws -> [WatchHealthSample] {
        var daily: [Date: Int] = [:]
        for itemStart in stride(from: 0, to: bytes.count - (bytes.count % itemSize), by: itemSize) {
            let itemEnd = itemStart + itemSize
            guard itemEnd <= bytes.count, itemSize >= 9 else { continue }
            let version = Int(try uint16(bytes, at: itemStart))
            guard [5, 6, 7, 8, 13].contains(version) else { continue }
            var timestamp = try uint32(bytes, at: itemStart + 2)
            let recordCount = Int(bytes[itemStart + 8])
            var cursor = itemStart + 9
            let recordSize = 6 + (version >= 6 ? 6 : 0) + (version >= 7 ? 1 : 0)
                + (version >= 8 ? 2 : 0) + (version >= 13 ? 1 : 0)
            for _ in 0..<recordCount where cursor + recordSize <= itemEnd {
                let steps = Int(bytes[cursor])
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                daily[Calendar.current.startOfDay(for: date), default: 0] += steps
                cursor += recordSize
                timestamp &+= 60
            }
        }
        return daily.map {
            WatchHealthSample(date: $0.key, steps: $0.value, sleepMinutes: 0, source: .watch)
        }
    }

    /// Sleep as the watch keeps it: one record per stretch, filed under the day
    /// it ended in.
    ///
    /// A restful stretch (types 2 and 4) lies *inside* a sleep or a nap and is
    /// the same minutes said again — `activity.h` is explicit that its start and
    /// end are always within the containing session. Adding all four types
    /// together, which this used to do, made a night with two hours of deep
    /// sleep ten hours long.
    private func sleepSamples(from bytes: [UInt8], itemSize: Int) throws -> [WatchHealthSample] {
        var daily: [Date: (intervals: [SleepInterval], timeZoneIdentifier: String)] = [:]
        for itemStart in stride(from: 0, to: bytes.count - (bytes.count % itemSize), by: itemSize) {
            let itemEnd = itemStart + itemSize
            guard itemEnd <= bytes.count, itemSize >= 18 else { continue }
            let type = try uint16(bytes, at: itemStart + 4)
            guard (1...4).contains(type) else { continue }
            let rawOffset = Int32(bitPattern: try uint32(bytes, at: itemStart + 6))
            let start = try uint32(bytes, at: itemStart + 10)
            let duration = try uint32(bytes, at: itemStart + 14)
            let timeZone = TimeZone(secondsFromGMT: Int(rawOffset)) ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let endDate = Date(timeIntervalSince1970: TimeInterval(start + duration))
            let day = calendar.startOfDay(for: endDate)
            var value = daily[day, default: ([], timeZone.identifier)]
            value.intervals.append(SleepInterval(
                start: Date(timeIntervalSince1970: TimeInterval(start)),
                duration: TimeInterval(duration),
                // Restful sleep, and restful nap.
                isDeep: type == 2 || type == 4
            ))
            daily[day] = value
        }
        return daily.map { day, value in
            let sessions = SleepSessions.grouped(value.intervals)
            return WatchHealthSample(
                date: day,
                steps: 0,
                sleepMinutes: min(24 * 60, sessions.reduce(0) { $0 + $1.asleepMinutes }),
                deepSleepMinutes: min(24 * 60, sessions.reduce(0) { $0 + $1.deepMinutes }),
                sleepSessions: sessions,
                timeZoneIdentifier: value.timeZoneIdentifier,
                source: .watch
            )
        }
    }

    private func uint16(_ bytes: [UInt8], at offset: Int) throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw HealthDataLoggingError.invalidPayload }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw HealthDataLoggingError.invalidPayload }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    @MemberwiseInit(.fileprivate)
    fileprivate struct Session: Sendable {
        var tag: UInt32
        var itemSize: Int
    }
}

public enum HealthDataLoggingCodec {
    public static var endpoint: UInt16 { 6_778 }
    public static func reportOpenSessionsFrame() -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x84])
    }
    public static func ackFrame(sessionID: UInt8) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x85, sessionID])
    }
    public static func nackFrame(sessionID: UInt8) -> PebbleProtocolFrame {
        PebbleProtocolFrame(endpoint: endpoint, payload: [0x86, sessionID])
    }
}

public enum HealthDataLoggingError: Error, Equatable, Sendable {
    case invalidPayload
    case invalidItemSize
}
