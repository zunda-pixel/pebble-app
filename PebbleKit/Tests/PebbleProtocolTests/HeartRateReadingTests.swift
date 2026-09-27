import Foundation
import Testing
@testable import PebbleProtocol

/// The measured minutes ride beside the day summary, for the HealthKit export.
@Suite
struct HeartRateReadingTests {
    private let now = Date(timeIntervalSince1970: 172_800)

    private func day(
        _ epoch: TimeInterval,
        readings: [HeartRateReading],
        source: WatchHealthDataSource = .watch,
        updatedAt: Date = Date(timeIntervalSince1970: 200)
    ) -> WatchHealthSample {
        WatchHealthSample(
            date: Date(timeIntervalSince1970: epoch),
            steps: 100,
            sleepMinutes: 0,
            heartRate: .from(readings.map(\.beatsPerMinute)),
            heartRateReadings: readings,
            source: source,
            updatedAt: updatedAt
        )
    }

    /// A HealthKit record for the same day carries no heart rate at all, and
    /// merging it in must not wipe the minutes the watch measured.
    @Test func aHealthKitDayDoesNotWipeTheWatchsMinutes() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        let reading = HeartRateReading(date: Date(timeIntervalSince1970: 90_060), beatsPerMinute: 72)
        _ = try await store.merge([day(86_400, readings: [reading])], now: now)

        var healthKitDay = day(86_400, readings: [], source: .healthKit, updatedAt: Date(timeIntervalSince1970: 300))
        healthKitDay.heartRate = nil
        let merged = try await store.merge([healthKitDay], now: now)

        let resolved = try #require(merged.first)
        #expect(resolved.heartRateReadings == [reading])
        #expect(resolved.heartRate?.average == 72)
    }

    /// The summary and its readings travel together: the newer watch record
    /// replaces both, never one without the other.
    @Test func aNewerWatchDayReplacesSummaryAndMinutesTogether() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        _ = try await store.merge([
            day(86_400, readings: [HeartRateReading(date: Date(timeIntervalSince1970: 90_060), beatsPerMinute: 72)]),
        ], now: now)

        let newer = [
            HeartRateReading(date: Date(timeIntervalSince1970: 90_060), beatsPerMinute: 72),
            HeartRateReading(date: Date(timeIntervalSince1970: 93_600), beatsPerMinute: 90),
        ]
        let merged = try await store.merge([
            day(86_400, readings: newer, updatedAt: Date(timeIntervalSince1970: 400)),
        ], now: now)

        let resolved = try #require(merged.first)
        #expect(resolved.heartRateReadings == newer)
        #expect(resolved.heartRate?.highest == 90)
    }

    private func reading(_ epoch: TimeInterval, _ beats: Int) -> HeartRateReading {
        HeartRateReading(date: Date(timeIntervalSince1970: epoch), beatsPerMinute: beats)
    }

    /// Each sync brings the minutes since the last one, so the evening's batch
    /// for a day adds to the morning's instead of replacing it, and the day's
    /// summary is of every minute measured.
    @Test func twoBatchesForOneDayKeepBothBatchesReadings() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        _ = try await store.merge([day(86_400, readings: [reading(90_060, 72)])], now: now)

        let merged = try await store.merge([
            day(86_400, readings: [reading(93_600, 90)], updatedAt: Date(timeIntervalSince1970: 400)),
        ], now: now)

        let resolved = try #require(merged.first)
        #expect(resolved.heartRateReadings == [reading(90_060, 72), reading(93_600, 90)])
        #expect(resolved.heartRate == WatchHeartRateSummary(lowest: 72, average: 81, highest: 90, measuredMinutes: 2))
    }

    /// A minute both batches measured is read as the newer batch has it,
    /// whichever order they arrive in.
    @Test(arguments: [false, true])
    func theNewerBatchWinsAMinuteBothMeasured(newerArrivesFirst: Bool) async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        let older = day(86_400, readings: [reading(90_060, 72), reading(93_600, 80)])
        let newer = day(86_400, readings: [reading(90_060, 76)], updatedAt: Date(timeIntervalSince1970: 400))
        _ = try await store.merge([newerArrivesFirst ? newer : older], now: now)

        let merged = try await store.merge([newerArrivesFirst ? older : newer], now: now)

        let resolved = try #require(merged.first)
        #expect(resolved.heartRateReadings == [reading(90_060, 76), reading(93_600, 80)])
        #expect(resolved.heartRate?.average == 78)
        #expect(resolved.heartRate?.measuredMinutes == 2)
    }

    /// Blood oxygen is measured and synchronized the same way, so it is
    /// joined the same way.
    @Test func bloodOxygenBatchesForOneDayAreJoinedToo() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        func batch(_ readings: [BloodOxygenReading], updatedAt: TimeInterval) -> WatchHealthSample {
            var sample = day(86_400, readings: [], updatedAt: Date(timeIntervalSince1970: updatedAt))
            sample.bloodOxygen = .from(readings.map(\.percent))
            sample.bloodOxygenReadings = readings
            return sample
        }
        let morning = BloodOxygenReading(date: Date(timeIntervalSince1970: 90_060), percent: 97)
        let evening = BloodOxygenReading(date: Date(timeIntervalSince1970: 93_600), percent: 93)
        _ = try await store.merge([batch([morning], updatedAt: 200)], now: now)

        let merged = try await store.merge([batch([evening], updatedAt: 400)], now: now)

        let resolved = try #require(merged.first)
        #expect(resolved.bloodOxygenReadings == [morning, evening])
        #expect(resolved.bloodOxygen == WatchBloodOxygenSummary(lowest: 93, average: 95, highest: 97, measuredMinutes: 2))
    }

    /// A file written before readings existed still opens, with none.
    @Test func aLegacyFileDecodesWithNoReadings() throws {
        let json = """
        {"date":100,"steps":10,"sleepMinutes":0,
         "heartRate":{"lowest":60,"average":70,"highest":80,"measuredMinutes":2}}
        """
        let decoded = try JSONDecoder().decode(WatchHealthSample.self, from: Data(json.utf8))

        #expect(decoded.heartRateReadings.isEmpty)
        #expect(decoded.heartRate?.average == 70)
    }
}
