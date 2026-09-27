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
