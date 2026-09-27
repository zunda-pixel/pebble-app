public import Foundation
import MemberwiseInit

/// Health samples the watch reports, and the file they are kept in.
@MemberwiseInit(.public)
public struct WatchHealthSample: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var date: Date
    public var steps: Int
    /// Every minute asleep, counting each one once.
    public var sleepMinutes: Int
    /// The restful part of `sleepMinutes`, not extra on top of it.
    public var deepSleepMinutes: Int = 0
    /// The night, and any nap, as the watch recorded them. Empty for a day that
    /// came from HealthKit or an older file, which knew only the total.
    public var sleepSessions: [SleepSession] = []
    /// What moving cost, over and above staying still.
    public var activeKilocalories: Int = 0
    /// What staying alive cost. Apple Health calls it basal energy.
    public var restingKilocalories: Int = 0
    public var distanceMetres: Int = 0
    /// Apple Health's exercise minutes: the part of the day that counted as
    /// effort, which is what the watch means by active time.
    public var activeMinutes: Int = 0
    /// The day's heart rate as the watch measured it, minute by minute.
    ///
    /// Nil where nothing measured it: a day from HealthKit, a file written
    /// before this existed, a watch with no sensor, or a day the sensor was
    /// off. Distinct from a day of zeroes, which would read as a heart that
    /// stopped.
    public var heartRate: WatchHeartRateSummary? = nil
    /// The measured minutes themselves, for the HealthKit export: a summary
    /// cannot honestly become per-moment samples again. Empty wherever
    /// `heartRate` is nil, and for files written before this existed.
    public var heartRateReadings: [HeartRateReading] = []
    /// The day's blood oxygen (SpO2) as the watch measured it, minute by minute.
    /// Nil under the same conditions as `heartRate`: nothing measured it — a day
    /// from HealthKit, an older file, a watch with no sensor, or the reading off.
    public var bloodOxygen: WatchBloodOxygenSummary? = nil
    /// The measured minutes themselves, for the HealthKit export. Empty wherever
    /// `bloodOxygen` is nil, and for files written before this existed.
    public var bloodOxygenReadings: [BloodOxygenReading] = []
    /// The walks, runs and open workouts the watch recorded, filed under the
    /// day they ended in. Empty for a day from HealthKit or an older file.
    public var workouts: [WatchWorkout] = []
    public var timeZoneIdentifier: String = TimeZone.current.identifier
    public var source: WatchHealthDataSource = .watch
    public var updatedAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, date, steps, sleepMinutes, deepSleepMinutes, sleepSessions
        case activeKilocalories, restingKilocalories, distanceMetres, activeMinutes
        case heartRate, heartRateReadings, bloodOxygen, bloodOxygenReadings
        case workouts, timeZoneIdentifier, source, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        steps = try container.decode(Int.self, forKey: .steps)
        sleepMinutes = try container.decode(Int.self, forKey: .sleepMinutes)
        deepSleepMinutes = try container.decodeIfPresent(Int.self, forKey: .deepSleepMinutes) ?? 0
        sleepSessions = try container.decodeIfPresent([SleepSession].self, forKey: .sleepSessions) ?? []
        activeKilocalories = try container.decodeIfPresent(Int.self, forKey: .activeKilocalories) ?? 0
        restingKilocalories = try container.decodeIfPresent(Int.self, forKey: .restingKilocalories) ?? 0
        distanceMetres = try container.decodeIfPresent(Int.self, forKey: .distanceMetres) ?? 0
        activeMinutes = try container.decodeIfPresent(Int.self, forKey: .activeMinutes) ?? 0
        heartRate = try container.decodeIfPresent(WatchHeartRateSummary.self, forKey: .heartRate)
        heartRateReadings = try container.decodeIfPresent([HeartRateReading].self, forKey: .heartRateReadings) ?? []
        bloodOxygen = try container.decodeIfPresent(WatchBloodOxygenSummary.self, forKey: .bloodOxygen)
        bloodOxygenReadings = try container.decodeIfPresent([BloodOxygenReading].self, forKey: .bloodOxygenReadings) ?? []
        workouts = try container.decodeIfPresent([WatchWorkout].self, forKey: .workouts) ?? []
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
        source = try container.decodeIfPresent(WatchHealthDataSource.self, forKey: .source) ?? .watch
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? date
    }
}

/// A day's heart rate, reduced to what a day-granular record can hold honestly.
///
/// The watch measures a beat count per minute and only for the minutes its
/// sensor ran, so a day is a handful of readings scattered through it rather
/// than a continuous line. `lowest` is the smallest measured minute and not a
/// resting heart rate: that is a derived figure with a definition of its own,
/// and calling this by that name would be claiming an algorithm this app does
/// not have.
@MemberwiseInit(.public)
public struct WatchHeartRateSummary: Codable, Equatable, Sendable {
    public var lowest: Int
    public var average: Int
    public var highest: Int
    /// How many minutes the watch actually measured, so a reader can tell an
    /// average over four minutes from one over four hours.
    public var measuredMinutes: Int

    /// Nil for a day with nothing measured, rather than a summary of zeroes.
    public static func from(_ beatsPerMinute: [Int]) -> Self? {
        guard let lowest = beatsPerMinute.min(), let highest = beatsPerMinute.max() else {
            return nil
        }
        return Self(
            lowest: lowest,
            average: beatsPerMinute.reduce(0, +) / beatsPerMinute.count,
            highest: highest,
            measuredMinutes: beatsPerMinute.count
        )
    }
}

/// One minute the sensor ran: when, and what it counted.
@MemberwiseInit(.public)
public struct HeartRateReading: Codable, Equatable, Sendable {
    public var date: Date
    public var beatsPerMinute: Int
}

/// A day's blood oxygen, reduced the same way `WatchHeartRateSummary` reduces the
/// heart rate: the watch measures a saturation percentage only for the minutes
/// its sensor ran, so a day is a scattered handful of readings, and `lowest` is
/// the smallest measured minute rather than any clinical figure.
@MemberwiseInit(.public)
public struct WatchBloodOxygenSummary: Codable, Equatable, Sendable {
    public var lowest: Int
    public var average: Int
    public var highest: Int
    /// How many minutes the watch actually measured.
    public var measuredMinutes: Int

    /// Nil for a day with nothing measured, rather than a summary of zeroes.
    public static func from(_ percentages: [Int]) -> Self? {
        guard let lowest = percentages.min(), let highest = percentages.max() else {
            return nil
        }
        return Self(
            lowest: lowest,
            average: percentages.reduce(0, +) / percentages.count,
            highest: highest,
            measuredMinutes: percentages.count
        )
    }
}

/// One minute the SpO2 sensor ran: when, and the saturation percentage it read.
@MemberwiseInit(.public)
public struct BloodOxygenReading: Codable, Equatable, Sendable {
    public var date: Date
    public var percent: Int
}

public enum WatchHealthDataSource: String, Codable, Equatable, Sendable {
    case watch
    case healthKit
    case imported
}

@MemberwiseInit(.public)
public struct WatchHealthArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var exportedAt: Date = Date()
    public var samples: [WatchHealthSample]
}

public actor WatchHealthStore {
    private var fileURL: URL

    public init(directory: StorageDirectory = .applicationSupport) {
        fileURL = directory.file("health.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func samples() throws -> [WatchHealthSample] { try PersistentJSON.loadRecovering([WatchHealthSample].self, from: fileURL) ?? [] }
    public func save(_ samples: [WatchHealthSample]) throws { try PersistentJSON.save(samples, to: fileURL) }
    public func merge(_ incoming: [WatchHealthSample]) throws -> [WatchHealthSample] {
        var merged: [String: WatchHealthSample] = [:]
        for sample in try samples() + incoming {
            let normalized = normalized(sample)
            let key = dayKey(for: normalized)
            guard let existing = merged[key] else {
                merged[key] = normalized
                continue
            }
            var resolved = normalized.updatedAt >= existing.updatedAt ? normalized : existing
            resolved.steps = max(existing.steps, normalized.steps)
            // Only Apple Health has these, so a record that has them is the
            // only one that can say anything: the watch's own record for the
            // same day carries zeroes and must not wipe them.
            resolved.activeKilocalories = max(existing.activeKilocalories, normalized.activeKilocalories)
            resolved.restingKilocalories = max(existing.restingKilocalories, normalized.restingKilocalories)
            resolved.distanceMetres = max(existing.distanceMetres, normalized.distanceMetres)
            resolved.activeMinutes = max(existing.activeMinutes, normalized.activeMinutes)
            // The other way round from the calories above: only the watch
            // measures this, so a HealthKit record for the same day carries
            // nil — and being the newer of the two would otherwise have wiped
            // what the watch measured. Whichever record has one keeps it, and
            // the newer wins only when both do.
            // The summary and its readings travel together: they are two
            // shapes of the same measurement, and splitting them across two
            // records would pair one day's average with another's minutes.
            switch (existing.heartRate, normalized.heartRate) {
            case (let older?, let newer?):
                if normalized.updatedAt >= existing.updatedAt {
                    resolved.heartRate = newer
                    resolved.heartRateReadings = normalized.heartRateReadings
                } else {
                    resolved.heartRate = older
                    resolved.heartRateReadings = existing.heartRateReadings
                }
            case (let only?, nil):
                resolved.heartRate = only
                resolved.heartRateReadings = existing.heartRateReadings
            case (nil, let only?):
                resolved.heartRate = only
                resolved.heartRateReadings = normalized.heartRateReadings
            case (nil, nil):
                resolved.heartRate = nil
                resolved.heartRateReadings = []
            }
            // Blood oxygen travels with its readings the same way heart rate
            // does, and for the same reason: only the watch measures it, so a
            // HealthKit record carries nil and must not wipe what the watch saw.
            switch (existing.bloodOxygen, normalized.bloodOxygen) {
            case (let older?, let newer?):
                if normalized.updatedAt >= existing.updatedAt {
                    resolved.bloodOxygen = newer
                    resolved.bloodOxygenReadings = normalized.bloodOxygenReadings
                } else {
                    resolved.bloodOxygen = older
                    resolved.bloodOxygenReadings = existing.bloodOxygenReadings
                }
            case (let only?, nil):
                resolved.bloodOxygen = only
                resolved.bloodOxygenReadings = existing.bloodOxygenReadings
            case (nil, let only?):
                resolved.bloodOxygen = only
                resolved.bloodOxygenReadings = normalized.bloodOxygenReadings
            case (nil, nil):
                resolved.bloodOxygen = nil
                resolved.bloodOxygenReadings = []
            }
            // Workouts arrive one sync at a time — the morning walk in the
            // morning, the evening run in the evening — so the day is the
            // union of both records, keyed by when each workout started, and
            // the newer record wins only where both tell the same workout.
            if !existing.workouts.isEmpty || !normalized.workouts.isEmpty {
                let (older, newer) = normalized.updatedAt >= existing.updatedAt
                    ? (existing, normalized) : (normalized, existing)
                var byStart: [Date: WatchWorkout] = [:]
                for workout in older.workouts + newer.workouts { byStart[workout.start] = workout }
                resolved.workouts = byStart.values.sorted { $0.start < $1.start }
            }
            // The night is taken whole from one record: its total, its
            // restful part and the sessions it was made of belong together,
            // and mixing two readings of one night makes a third that nobody
            // slept. Whichever record has a night keeps it, the same as heart
            // rate, and the newer wins only when both do — a record with no
            // sleep in it, like a HealthKit day of steps, says nothing about
            // the night.
            let takesIncomingNight = normalized.sleepMinutes > 0
                && (existing.sleepMinutes == 0 || normalized.updatedAt >= existing.updatedAt)
            if takesIncomingNight {
                resolved.sleepMinutes = normalized.sleepMinutes
                resolved.deepSleepMinutes = normalized.deepSleepMinutes
                resolved.sleepSessions = normalized.sleepSessions
            } else {
                resolved.sleepMinutes = existing.sleepMinutes
                resolved.deepSleepMinutes = existing.deepSleepMinutes
                resolved.sleepSessions = existing.sleepSessions
            }
            merged[key] = resolved
        }
        var values = Array(merged.values)
        values.sort { $0.date < $1.date }
        try save(values)
        return values
    }
    public func deleteAll() throws { try? FileManager.default.removeItem(at: fileURL) }
    public func export() throws -> URL {
        let output = FileManager.default.temporaryDirectory.appending(path: "pebble-health.json")
        let archive = WatchHealthArchive(samples: try samples())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: output, options: .atomic)
        return output
    }

    public func importArchive(from url: URL) throws -> [WatchHealthSample] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let archive = try? decoder.decode(WatchHealthArchive.self, from: data) {
            guard archive.schemaVersion == 1 else { throw WatchHealthArchiveError.unsupportedVersion }
            return try merge(archive.samples.map { sample in
                var value = sample
                value.source = .imported
                return value
            })
        }
        let legacyDecoder = JSONDecoder()
        let legacy = try legacyDecoder.decode([WatchHealthSample].self, from: data)
        return try merge(legacy.map { sample in
            var value = sample
            value.source = .imported
            return value
        })
    }

    private func normalized(_ sample: WatchHealthSample) -> WatchHealthSample {
        var value = sample
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: sample.timeZoneIdentifier) ?? .current
        value.date = calendar.startOfDay(for: sample.date)
        value.steps = max(0, sample.steps)
        value.sleepMinutes = min(24 * 60, max(0, sample.sleepMinutes))
        value.deepSleepMinutes = min(value.sleepMinutes, max(0, sample.deepSleepMinutes))
        value.activeKilocalories = max(0, sample.activeKilocalories)
        value.restingKilocalories = max(0, sample.restingKilocalories)
        value.distanceMetres = max(0, sample.distanceMetres)
        value.activeMinutes = min(24 * 60, max(0, sample.activeMinutes))
        return value
    }

    private func dayKey(for sample: WatchHealthSample) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: sample.timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: sample.date)
        let year = String(components.year ?? 0)
        let month = String(components.month ?? 0)
        let day = String(components.day ?? 0)
        return "\(String(repeating: "0", count: max(0, 4 - year.count)))\(year)"
            + "-\(String(repeating: "0", count: max(0, 2 - month.count)))\(month)"
            + "-\(String(repeating: "0", count: max(0, 2 - day.count)))\(day)"
    }
}

public enum WatchHealthArchiveError: Error, Equatable, Sendable { case unsupportedVersion }

public enum HealthAnalysisPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month, quarter
    public var id: Self { self }
    public var days: Int { self == .week ? 7 : self == .month ? 30 : 90 }
}
