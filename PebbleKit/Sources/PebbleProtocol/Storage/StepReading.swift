public import Foundation
import MemberwiseInit

/// One minute the watch counted steps in: when it began, and how many.
@MemberwiseInit(.public)
public struct StepReading: Codable, Equatable, Sendable {
    public var date: Date
    public var steps: Int

    public var end: Date { date.addingTimeInterval(60) }
}

/// A stretch of consecutive minutes with steps in them, as HealthKit takes it.
@MemberwiseInit(.public)
public struct StepInterval: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var steps: Int

    /// Joins each run of back-to-back minutes into one interval. A minute
    /// with no steps is not a reading, so it is where one interval ends.
    public static func coalescing(_ readings: [StepReading]) -> [StepInterval] {
        var intervals: [StepInterval] = []
        for reading in readings.sorted(by: { $0.date < $1.date }) where reading.steps > 0 {
            if let last = intervals.last, reading.date <= last.end {
                intervals[intervals.count - 1].end = max(last.end, reading.end)
                intervals[intervals.count - 1].steps += reading.steps
            } else {
                intervals.append(StepInterval(start: reading.date, end: reading.end, steps: reading.steps))
            }
        }
        return intervals
    }
}
