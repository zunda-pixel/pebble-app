import Foundation
import Testing
@testable import PebbleTransport
@testable import PebbleProtocol
@testable import PebbleApp

/// The health settings the screen was missing, and the long-term statistics
/// the watch compares a day against (#96).
@Suite
@MainActor
struct HealthStatsTests {
    // MARK: Heart-rate zones

    /// `HeartRatePreferences` in `activity.h`: six packed bytes, in order.
    @Test func theZonePreferencesAreSixBytesInStructOrder() {
        let preferences = HeartRateZonePreferences(
            restingBPM: 60, elevatedBPM: 95, maximumBPM: 185,
            zone1BPM: 125, zone2BPM: 150, zone3BPM: 170
        )

        #expect(preferences.encoded() == [60, 95, 185, 125, 150, 170])
        let frame = HealthSettingsCodec.insertFrame(preferences, token: 1)
        #expect(Array(frame.payload.suffix(6)) == [60, 95, 185, 125, 150, 170])
    }

    /// The two chains the firmware's own handler enforces. A record that
    /// breaks either would be refused whole and reset to defaults, so nothing
    /// disordered may leave the phone.
    @Test func disorderedZonesAreInvalid() {
        #expect(HeartRateZonePreferences().isValid)
        #expect(!HeartRateZonePreferences(restingBPM: 120, elevatedBPM: 100).isValid)
        #expect(!HeartRateZonePreferences(elevatedBPM: 200, maximumBPM: 190).isValid)
        #expect(!HeartRateZonePreferences(zone1BPM: 160, zone2BPM: 150).isValid)
        #expect(!HeartRateZonePreferences(zone2BPM: 180, zone3BPM: 172).isValid)
        #expect(!HeartRateZonePreferences(restingBPM: 0).isValid)
    }

    /// The firmware default: 70 / 100 / (220 − 30), zones at 130/154/172.
    @Test func theDefaultsAreTheFirmwares() {
        let preferences = HeartRateZonePreferences()
        #expect(preferences.encoded() == [70, 100, 190, 130, 154, 172])
    }

    // MARK: Thirty-day averages

    private func sample(daysAgo: Int, steps: Int, sleepMinutes: Int, now: Date) -> WatchHealthSample {
        let calendar = Calendar.current
        let day = calendar.date(
            byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)
        )!
        return WatchHealthSample(date: day, steps: steps, sleepMinutes: sleepMinutes)
    }

    @Test func theAverageSkipsDaysWithNothingToSay() throws {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let samples = [
            sample(daysAgo: 1, steps: 8_000, sleepMinutes: 400, now: now),
            sample(daysAgo: 2, steps: 12_000, sleepMinutes: 0, now: now),
            // Off the wrist: says nothing about either.
            sample(daysAgo: 3, steps: 0, sleepMinutes: 0, now: now),
            // Outside the month: not counted.
            sample(daysAgo: 40, steps: 90_000, sleepMinutes: 900, now: now),
            // Today is still being counted and is not an average's business.
            sample(daysAgo: 0, steps: 500, sleepMinutes: 0, now: now),
        ]

        // Unpacked before comparing: `#expect` on a labelled tuple through
        // optional chaining reported the operands equal and the comparison
        // false, so the members are taken out where the macro cannot touch
        // them.
        let averages = try #require(AppModel.thirtyDayAverages(of: samples, now: now))
        let steps = averages.steps
        let sleepSeconds = averages.sleepSeconds

        #expect(steps == 10_000)
        #expect(sleepSeconds == 24_000)
    }

    @Test func noHistoryMeansNoAverageAtAll() {
        #expect(AppModel.thirtyDayAverages(of: [], now: .now) == nil)
    }

    // MARK: Typical sleep per weekday

    @Test func theTypicalIsTheMedianOfThatWeekdayAlone() throws {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let startOfToday = calendar.startOfDay(for: now)
        // Three of the same weekday, 7/14/21 days back, and one other day.
        let weekday = calendar.dateComponents(
            [.weekday],
            from: calendar.date(byAdding: .day, value: -7, to: startOfToday)!
        ).weekday! - 1
        let samples = [
            sample(daysAgo: 7, steps: 0, sleepMinutes: 300, now: now),
            sample(daysAgo: 14, steps: 0, sleepMinutes: 480, now: now),
            sample(daysAgo: 21, steps: 0, sleepMinutes: 420, now: now),
            sample(daysAgo: 8, steps: 0, sleepMinutes: 90, now: now),
        ]

        let typical = try #require(
            AppModel.typicalSleep(onWeekday: weekday, of: samples, before: startOfToday)
        )
        let sleep = typical.sleep

        // The median of 300/420/480 is 420 — one short night does not move
        // what "usual" means, and the other weekday's 90 is not counted.
        #expect(sleep == 25_200)
    }

    @Test func aWeekdayWithNoHistoryHasNoTypical() {
        let now = Date(timeIntervalSince1970: 1_757_000_000)
        let startOfToday = Calendar.current.startOfDay(for: now)
        #expect(AppModel.typicalSleep(onWeekday: 0, of: [], before: startOfToday) == nil)
    }

    // MARK: The wire

    /// `health_db.c` builds the keys as `"average" + suffix` and reads one
    /// `uint32` from each.
    @Test func theAveragesTravelUnderTheKeysTheFirmwareBuilds() {
        let steps = HealthStatsCodec.averageStepsFrame(steps: 9_500, token: 1)
        let sleep = HealthStatsCodec.averageSleepFrame(seconds: 27_000, token: 2)

        let stepsPayload = steps.payload
        #expect(String(decoding: stepsPayload, as: UTF8.self).contains("average_dailySteps"))
        #expect(Array(stepsPayload.suffix(4)) == [0x1C, 0x25, 0, 0])
        #expect(String(decoding: sleep.payload, as: UTF8.self).contains("average_sleepDuration"))
    }

    /// The typicals ride the SleepData record where history exists, and fall
    /// back to the day's own values where it does not.
    @Test func theSleepRecordCarriesTypicalsWhereThereAreAny() {
        var day = WatchHealthDay(
            weekday: 2,
            lastProcessed: Date(timeIntervalSince1970: 1_757_000_000),
            steps: 0, activeKilocalories: 0, restingKilocalories: 0,
            distanceMetres: 0, activeSeconds: 0,
            sleepSeconds: 6 * 3600, deepSleepSeconds: 3600
        )

        let own = HealthStatsCodec.sleepValue(for: day)
        // typical_sleep_duration sits at offset 24 (七th uint32).
        #expect(Array(own[24..<28]) == UInt32(6 * 3600).littleEndianBytes)

        day.typicalSleepSeconds = 7 * 3600
        day.typicalDeepSleepSeconds = 5400
        let informed = HealthStatsCodec.sleepValue(for: day)
        #expect(Array(informed[24..<28]) == UInt32(7 * 3600).littleEndianBytes)
        #expect(Array(informed[28..<32]) == UInt32(5400).littleEndianBytes)
    }
}
