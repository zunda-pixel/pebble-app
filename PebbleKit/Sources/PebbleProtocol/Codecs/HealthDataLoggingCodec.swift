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
        // 81 and only 81. `DlsSystemTagActivityMinuteData` is the minute data;
        // 85 is `DlsSystemTagProtobufLogSession`
        // (`include/pbl/services/data_logging/data_logging_service.h`), and
        // reading protobuf as minutes filed a day in 1996 with whatever byte 0
        // of each 97-byte stretch happened to be. Measured on the test watch:
        // a tag-85 session opens on every connect and its first bytes are
        // `12 0c` followed by the watch's serial, which is a protobuf field,
        // not a record header. The official app's `HEALTH_HR_TAG = 85` says
        // otherwise and is wrong here; the firmware and the wire agree.
        case 81:
            return try stepSamples(from: bytes, itemSize: session.itemSize)
        case 83, 84:
            return try sessionSamples(from: bytes, itemSize: session.itemSize)
        default:
            return []
        }
    }

    /// Where the fields this reads sit inside one minute of `AlgMinuteDLSSample`
    /// (`include/pbl/services/activity/activity_algorithm.h`).
    ///
    /// | byte | field | since version |
    /// | --- | --- | --- |
    /// | 0 | steps | 4 |
    /// | 1–5 | orientation, vmc, light, flags | 4–5 |
    /// | 6–11 | resting and active calories, distance | 6 |
    /// | 12 | heart rate | 7 |
    /// | 13–15 | heart rate weight and zone | 12, 13 |
    private enum MinuteSample {
        static let steps = 0
        static let heartRate = 12
        static let firstVersionWithHeartRate = 7
    }

    private func stepSamples(from bytes: [UInt8], itemSize: Int) throws -> [WatchHealthSample] {
        var daily: [Date: (steps: Int, heartRates: [HeartRateReading])] = [:]
        for itemStart in stride(from: 0, to: bytes.count - (bytes.count % itemSize), by: itemSize) {
            let itemEnd = itemStart + itemSize
            guard itemEnd <= bytes.count, itemSize >= 9 else { continue }
            let version = Int(try uint16(bytes, at: itemStart))
            var timestamp = try uint32(bytes, at: itemStart + 2)
            // The record says how big its samples are, at byte 7 of the header,
            // and this used to work the same number out from the version — off
            // a list of versions that had 8 in it, which has never existed, and
            // not 4 or 12, which do (#112). Reading what the watch wrote also
            // means a version added after this was written parses rather than
            // being dropped, which is what the firmware's own note asks for:
            // "only appending more properties is allowed".
            let recordSize = Int(bytes[itemStart + 7])
            let recordCount = Int(bytes[itemStart + 8])
            guard recordSize > MinuteSample.steps else { continue }
            var cursor = itemStart + 9
            for _ in 0..<recordCount where cursor + recordSize <= itemEnd {
                let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                let day = Calendar.current.startOfDay(for: date)
                var entry = daily[day] ?? (steps: 0, heartRates: [])
                entry.steps += Int(bytes[cursor + MinuteSample.steps])
                // Zero is the watch saying it did not measure this minute, not
                // a heart that stopped: averaging it in would halve the day.
                if version >= MinuteSample.firstVersionWithHeartRate,
                   recordSize > MinuteSample.heartRate {
                    let beats = Int(bytes[cursor + MinuteSample.heartRate])
                    // The moment is kept with the count: HealthKit takes
                    // per-minute samples, and a day summary cannot honestly
                    // be turned back into moments.
                    if beats > 0 {
                        entry.heartRates.append(HeartRateReading(date: date, beatsPerMinute: beats))
                    }
                }
                daily[day] = entry
                cursor += recordSize
                timestamp &+= 60
            }
        }
        return daily.map { day, entry in
            WatchHealthSample(
                date: day,
                steps: entry.steps,
                sleepMinutes: 0,
                heartRate: .from(entry.heartRates.map(\.beatsPerMinute)),
                heartRateReadings: entry.heartRates,
                source: .watch
            )
        }
    }

    /// Where the fields this reads sit inside one
    /// `ActivitySessionDataLoggingRecord` (`activity_private.h`): the type at
    /// byte 4, the UTC offset, start and length after it, and — from logging
    /// version 3 — what a stepping session cost (`ActivitySessionDataStepping`
    /// in `activity.h`), four little-endian words from byte 18.
    private enum SessionRecord {
        static let type = 4
        static let utcOffset = 6
        static let start = 10
        static let duration = 14
        static let steps = 18
        static let activeKilocalories = 20
        static let restingKilocalories = 22
        static let distanceMetres = 24
        static let sizeWithStepping = 26
    }

    /// Sleep and workouts as the watch keeps them: one record per session,
    /// filed under the day it ended in.
    ///
    /// A restful stretch (types 2 and 4) lies *inside* a sleep or a nap and is
    /// the same minutes said again — `activity.h` is explicit that its start and
    /// end are always within the containing session. Adding all four types
    /// together, which this used to do, made a night with two hours of deep
    /// sleep ten hours long. Walks, runs and open workouts (types 5–7) travel
    /// on the same session and stand alone.
    private func sessionSamples(from bytes: [UInt8], itemSize: Int) throws -> [WatchHealthSample] {
        var daily: [Date: (intervals: [SleepInterval], workouts: [WatchWorkout], timeZoneIdentifier: String)] = [:]
        for itemStart in stride(from: 0, to: bytes.count - (bytes.count % itemSize), by: itemSize) {
            let itemEnd = itemStart + itemSize
            guard itemEnd <= bytes.count, itemSize >= 18 else { continue }
            let type = try uint16(bytes, at: itemStart + SessionRecord.type)
            guard (1...7).contains(type) else { continue }
            let rawOffset = Int32(bitPattern: try uint32(bytes, at: itemStart + SessionRecord.utcOffset))
            let start = try uint32(bytes, at: itemStart + SessionRecord.start)
            let duration = try uint32(bytes, at: itemStart + SessionRecord.duration)
            let timeZone = TimeZone(secondsFromGMT: Int(rawOffset)) ?? .current
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let endDate = Date(timeIntervalSince1970: TimeInterval(start + duration))
            let day = calendar.startOfDay(for: endDate)
            var value = daily[day, default: ([], [], timeZone.identifier)]
            switch type {
            case 1...4:
                value.intervals.append(SleepInterval(
                    start: Date(timeIntervalSince1970: TimeInterval(start)),
                    duration: TimeInterval(duration),
                    // Restful sleep, and restful nap.
                    isDeep: type == 2 || type == 4
                ))
            default:
                // A record from before logging version 3 ends at the length:
                // when and how long are known, what it cost is not.
                let counted = itemSize >= SessionRecord.sizeWithStepping
                value.workouts.append(WatchWorkout(
                    start: Date(timeIntervalSince1970: TimeInterval(start)),
                    duration: TimeInterval(duration),
                    kind: type == 5 ? .walk : type == 6 ? .run : .open,
                    steps: counted ? Int(try uint16(bytes, at: itemStart + SessionRecord.steps)) : 0,
                    activeKilocalories: counted
                        ? Int(try uint16(bytes, at: itemStart + SessionRecord.activeKilocalories)) : 0,
                    restingKilocalories: counted
                        ? Int(try uint16(bytes, at: itemStart + SessionRecord.restingKilocalories)) : 0,
                    distanceMetres: counted
                        ? Int(try uint16(bytes, at: itemStart + SessionRecord.distanceMetres)) : 0
                ))
            }
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
                workouts: value.workouts.sorted { $0.start < $1.start },
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
