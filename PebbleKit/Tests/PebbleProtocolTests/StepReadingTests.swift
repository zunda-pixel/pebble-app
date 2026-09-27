import Foundation
import Testing
@testable import PebbleProtocol

@Suite
struct StepReadingTests {
    private let start = Date(timeIntervalSince1970: 1_757_000_000)

    private func minute(_ offset: Int, steps: Int) -> StepReading {
        StepReading(date: start.addingTimeInterval(TimeInterval(offset * 60)), steps: steps)
    }

    @Test func backToBackMinutesBecomeOneInterval() {
        let intervals = StepInterval.coalescing([minute(0, steps: 10), minute(1, steps: 20), minute(2, steps: 5)])

        #expect(intervals == [
            StepInterval(start: start, end: start.addingTimeInterval(180), steps: 35),
        ])
    }

    @Test func aMinuteWithoutStepsSeparatesTwoIntervals() {
        let intervals = StepInterval.coalescing([
            minute(5, steps: 7),
            minute(0, steps: 10),
            minute(1, steps: 20),
            minute(3, steps: 0),
        ])

        #expect(intervals == [
            StepInterval(start: start, end: start.addingTimeInterval(120), steps: 30),
            StepInterval(start: start.addingTimeInterval(300), end: start.addingTimeInterval(360), steps: 7),
        ])
    }

    @Test func noReadingsIsNoIntervals() {
        #expect(StepInterval.coalescing([]).isEmpty)
    }

    @Test func theDayIsTheUnionOfEachSyncsMinutes() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        let day = Calendar.current.startOfDay(for: start)
        let morning = [minute(0, steps: 10), minute(1, steps: 20)]
        let evening = [minute(600, steps: 40)]
        let first = try await store.merge([WatchHealthSample(
            date: day, steps: 30, stepReadings: morning, sleepMinutes: 0,
            updatedAt: start.addingTimeInterval(120)
        )], now: start)

        let merged = try await store.merge([WatchHealthSample(
            date: day, steps: 40, stepReadings: evening, sleepMinutes: 0,
            updatedAt: start.addingTimeInterval(36_060)
        )], now: start)

        let resolved = try #require(merged.first)
        #expect(resolved.stepReadings == morning + evening)
        #expect(resolved.steps == 70)
        #expect(resolved.id == first.first?.id)
    }

    @Test func minutesAreReadFromTheWatchsRecord() throws {
        var processor = HealthDataLoggingProcessor()
        var record: [UInt8] = [13, 0]
        record += (0..<4).map { UInt8((UInt32(1_757_000_000) >> (8 * UInt32($0))) & 0xFF) }
        record += [0, 16, 3]
        for steps: UInt8 in [10, 0, 20] {
            var sample = [UInt8](repeating: 0, count: 16)
            sample[0] = steps
            record += sample
        }
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = 7
        open[22] = 81
        open[27] = UInt8(record.count & 0xFF)
        open[28] = UInt8(record.count >> 8)
        _ = try processor.process(PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open))
        let data: [UInt8] = [0x02, 7] + [UInt8](repeating: 0, count: 8) + record

        let result = try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)
        )
        let day = try #require(result.samples.first)

        #expect(day.steps == 30)
        #expect(day.stepReadings == [minute(0, steps: 10), minute(2, steps: 20)])
    }

    @Test func aFileWrittenBeforeMinutesWereKeptStillOpens() throws {
        let json = """
        {"date":100,"steps":10,"sleepMinutes":0}
        """
        let decoded = try JSONDecoder().decode(WatchHealthSample.self, from: Data(json.utf8))

        #expect(decoded.stepReadings.isEmpty)
        #expect(decoded.steps == 10)
    }
}

@Suite
struct MinuteDataRetentionTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func day(daysAgo: Int) -> WatchHealthSample {
        let date = now.addingTimeInterval(TimeInterval(-daysAgo * 86_400))
        return WatchHealthSample(
            date: date,
            steps: 1_000,
            stepReadings: [StepReading(date: date, steps: 1_000)],
            sleepMinutes: 420,
            activeKilocalories: 300,
            heartRate: .from([70]),
            heartRateReadings: [HeartRateReading(date: date, beatsPerMinute: 70)],
            bloodOxygen: .from([97]),
            bloodOxygenReadings: [BloodOxygenReading(date: date, percent: 97)],
            workouts: [WatchWorkout(start: date, duration: 600, kind: .walk, steps: 800)],
            timeZoneIdentifier: "UTC",
            updatedAt: date
        )
    }

    @Test func anOldDayKeepsItsSummariesAndLosesItsMinutes() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)

        let merged = try await store.merge([day(daysAgo: 31)], now: now)

        let old = try #require(merged.first)
        #expect(old.stepReadings.isEmpty)
        #expect(old.heartRateReadings.isEmpty)
        #expect(old.bloodOxygenReadings.isEmpty)
        #expect(old.steps == 1_000)
        #expect(old.sleepMinutes == 420)
        #expect(old.activeKilocalories == 300)
        #expect(old.heartRate?.average == 70)
        #expect(old.bloodOxygen?.average == 97)
        #expect(old.workouts.count == 1)
        #expect(try await store.samples() == merged)
    }

    @Test func aRecentDayKeepsBoth() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)

        let merged = try await store.merge([day(daysAgo: 29)], now: now)

        let recent = try #require(merged.first)
        #expect(recent.stepReadings.count == 1)
        #expect(recent.heartRateReadings.count == 1)
        #expect(recent.bloodOxygenReadings.count == 1)
        #expect(recent.heartRate?.average == 70)
    }
}
