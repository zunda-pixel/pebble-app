public import Foundation
import MemberwiseInit

/// One stretch the watch called sleep.
///
/// A deep one always lies inside a light one: the firmware records a restful
/// period as a session of its own that starts and ends within the sleep or nap
/// session it belongs to (`ActivitySessionType_RestfulSleep` in `activity.h`).
/// The two are the same minutes told twice, which is why only the containers
/// are added up.
@MemberwiseInit(.public)
public struct SleepInterval: Codable, Equatable, Sendable {
    public var start: Date
    public var duration: TimeInterval
    public var isDeep: Bool = false

    public var end: Date { start.addingTimeInterval(duration) }
}

/// A night, or a nap: the stretches that ran into each other.
@MemberwiseInit(.public)
public struct SleepSession: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// Time asleep, counting each minute once.
    public var asleep: TimeInterval = 0
    public var deep: TimeInterval = 0
    public var intervals: [SleepInterval] = []

    public var asleepMinutes: Int { Int(asleep / 60) }
    public var deepMinutes: Int { Int(deep / 60) }
}

/// One non-overlapping piece of a session, the shape an export can write.
@MemberwiseInit(.public)
public struct SleepStageSegment: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var isDeep: Bool
}

public extension SleepSession {
    /// The session cut into non-overlapping stage segments.
    ///
    /// The firmware records a restful stretch *inside* the sleep it belongs to
    /// — the same minutes told twice — so writing the intervals as they are
    /// would double-count the night. The deep stretches are kept whole and the
    /// light ones lose the minutes the deep ones already tell.
    ///
    /// A session from a file written before intervals were kept has none; the
    /// whole session comes back as one light segment, because the deep
    /// minutes' positions are genuinely unknown and placing them anywhere
    /// would be invention.
    var stageSegments: [SleepStageSegment] {
        guard !intervals.isEmpty else {
            return [SleepStageSegment(start: start, end: end, isDeep: false)]
        }
        let deepRanges = Self.merged(intervals.filter(\.isDeep))
        let lightRanges = Self.merged(intervals.filter { !$0.isDeep })
        var segments = deepRanges.map { SleepStageSegment(start: $0.start, end: $0.end, isDeep: true) }
        for light in lightRanges {
            var cursor = light.start
            for deep in deepRanges where deep.end > light.start && deep.start < light.end {
                if deep.start > cursor {
                    segments.append(SleepStageSegment(start: cursor, end: deep.start, isDeep: false))
                }
                cursor = max(cursor, deep.end)
            }
            if cursor < light.end {
                segments.append(SleepStageSegment(start: cursor, end: light.end, isDeep: false))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// Overlapping and touching stretches folded into disjoint ranges,
    /// oldest first.
    private static func merged(_ intervals: [SleepInterval]) -> [(start: Date, end: Date)] {
        var ranges: [(start: Date, end: Date)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, interval.start <= last.end {
                ranges[ranges.count - 1].end = max(last.end, interval.end)
            } else {
                ranges.append((interval.start, interval.end))
            }
        }
        return ranges
    }
}

public enum SleepSessions {
    /// How long a gap can be and still be the same night. Waking to turn over
    /// is not the end of a sleep; going for breakfast is. An hour is where the
    /// official app draws it too.
    public static let sessionGap: TimeInterval = 3600

    /// The stretches gathered into sessions, oldest first.
    public static func grouped(_ intervals: [SleepInterval]) -> [SleepSession] {
        var sessions: [SleepSession] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if var last = sessions.last, interval.start <= last.end.addingTimeInterval(sessionGap) {
                last.end = max(last.end, interval.end)
                if interval.isDeep { last.deep += interval.duration } else { last.asleep += interval.duration }
                last.intervals.append(interval)
                sessions[sessions.count - 1] = last
            } else {
                sessions.append(SleepSession(
                    start: interval.start,
                    end: interval.end,
                    asleep: interval.isDeep ? 0 : interval.duration,
                    deep: interval.isDeep ? interval.duration : 0,
                    intervals: [interval]
                ))
            }
        }
        return sessions
    }
}

/// What a run of days came to on an ordinary one.
@MemberwiseInit(.public)
public struct WatchHealthAverages: Equatable, Sendable {
    public var steps: Int = 0
    public var sleepMinutes: Int = 0
    public var deepSleepMinutes: Int = 0
    /// Days that had anything to say. A watch left in a drawer on Sunday should
    /// not make the week look lazier than it was, so the days with nothing are
    /// left out of the division rather than counted as zero.
    public var stepDays: Int = 0
    public var sleepDays: Int = 0

    public var isEmpty: Bool { stepDays == 0 && sleepDays == 0 }
}

public extension Sequence<WatchHealthSample> {
    /// The last `days` days, not counting today: today is still happening and
    /// would pull every average down.
    func averages(
        over days: Int,
        endingBefore now: Date = Date(),
        calendar: Calendar = .current
    ) -> WatchHealthAverages {
        let startOfToday = calendar.startOfDay(for: now)
        guard days > 0, let oldest = calendar.date(byAdding: .day, value: -days, to: startOfToday) else {
            return WatchHealthAverages()
        }
        var averages = WatchHealthAverages()
        var steps = 0
        var sleep = 0
        var deep = 0
        for sample in self {
            let day = calendar.startOfDay(for: sample.date)
            guard day >= oldest, day < startOfToday else { continue }
            if sample.steps > 0 {
                steps += sample.steps
                averages.stepDays += 1
            }
            if sample.sleepMinutes > 0 {
                sleep += sample.sleepMinutes
                deep += sample.deepSleepMinutes
                averages.sleepDays += 1
            }
        }
        averages.steps = averages.stepDays > 0 ? steps / averages.stepDays : 0
        averages.sleepMinutes = averages.sleepDays > 0 ? sleep / averages.sleepDays : 0
        averages.deepSleepMinutes = averages.sleepDays > 0 ? deep / averages.sleepDays : 0
        return averages
    }
}
