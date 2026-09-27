import Foundation
import Testing
@testable import PebbleProtocol

/// Workouts travel on the same data-logging session as sleep, one
/// `ActivitySessionDataLoggingRecord` per finished walk, run or open workout
/// (`activity_sessions.c`). From logging version 3 the record carries what the
/// workout cost: steps, active and resting kilocalories and distance, four
/// little-endian words from byte 18 (`ActivitySessionDataStepping`).
@Suite
struct WorkoutRecordTests {
    /// One session record: type, the seconds east of UTC, the start, the
    /// length, and — when `cost` is given — the version-3 stepping data.
    private func sessionItem(
        type: UInt16,
        start: UInt32,
        duration: UInt32,
        cost: (steps: UInt16, active: UInt16, resting: UInt16, distance: UInt16)? = nil
    ) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 0, 0]
            + type.littleEndianBytes
            + UInt32(0).littleEndianBytes
            + start.littleEndianBytes
            + duration.littleEndianBytes
        if let cost {
            bytes += cost.steps.littleEndianBytes
            bytes += cost.active.littleEndianBytes
            bytes += cost.resting.littleEndianBytes
            bytes += cost.distance.littleEndianBytes
        }
        return bytes
    }

    private func decoded(itemSize: Int, items: [[UInt8]]) throws -> [WatchHealthSample] {
        var processor = HealthDataLoggingProcessor()
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = 3
        open[22] = 83
        open[27] = UInt8(itemSize & 0xFF)
        open[28] = UInt8(itemSize >> 8)
        _ = try processor.process(PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open))
        var data: [UInt8] = [0x02, 3] + [UInt8](repeating: 0, count: 8)
        // Every record in a session is the same size on the wire: a sleep
        // record in a version-3 session still occupies the full item.
        for item in items { data += item + [UInt8](repeating: 0, count: max(0, itemSize - item.count)) }
        return try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: data)
        ).samples
    }

    /// A version-3 walk arrives with what it cost, and a run in the same batch
    /// keeps its own kind.
    @Test func aWalkAndARunAreReadWithWhatTheyCost() throws {
        let read = try decoded(itemSize: 26, items: [
            sessionItem(type: 5, start: 1_788_330_000, duration: 1_800,
                        cost: (steps: 2_400, active: 110, resting: 40, distance: 1_900)),
            sessionItem(type: 6, start: 1_788_340_000, duration: 2_400,
                        cost: (steps: 4_800, active: 320, resting: 55, distance: 5_200)),
        ])

        let day = try #require(read.first)
        #expect(day.workouts == [
            WatchWorkout(
                start: Date(timeIntervalSince1970: 1_788_330_000), duration: 1_800, kind: .walk,
                steps: 2_400, activeKilocalories: 110, restingKilocalories: 40, distanceMetres: 1_900
            ),
            WatchWorkout(
                start: Date(timeIntervalSince1970: 1_788_340_000), duration: 2_400, kind: .run,
                steps: 4_800, activeKilocalories: 320, restingKilocalories: 55, distanceMetres: 5_200
            ),
        ])
    }

    /// Sleep and a workout share the session and neither eats the other: the
    /// walk does not become sleep minutes, and the night does not become a
    /// workout.
    @Test func aWorkoutBesideTheNightLeavesTheNightAlone() throws {
        let read = try decoded(itemSize: 26, items: [
            sessionItem(type: 1, start: 1_788_303_600, duration: 7 * 3600),
            sessionItem(type: 7, start: 1_788_340_000, duration: 3_600,
                        cost: (steps: 100, active: 250, resting: 60, distance: 0)),
        ])

        let day = try #require(read.first)
        #expect(day.sleepMinutes == 7 * 60)
        #expect(day.workouts.map(\.kind) == [.open])
        #expect(day.workouts.first?.activeKilocalories == 250)
    }

    /// A record from before logging version 3 ends at the length: the workout
    /// is kept for when and how long, with nothing invented for its cost.
    @Test func anOldRecordKeepsTheWorkoutWithoutInventingItsCost() throws {
        let read = try decoded(itemSize: 18, items: [
            sessionItem(type: 6, start: 1_788_340_000, duration: 1_200)
        ])

        let workout = try #require(read.first?.workouts.first)
        #expect(workout.kind == .run)
        #expect(workout.duration == 1_200)
        #expect(workout.steps == 0)
        #expect(workout.distanceMetres == 0)
    }

    @Test func aRecordWhoseEndIsPastTheWatchClockIsSkippedAndTheRestKept() throws {
        let read = try decoded(itemSize: 18, items: [
            sessionItem(type: 6, start: UInt32.max - 10, duration: 1_200),
            sessionItem(type: 5, start: 1_788_340_000, duration: 600),
        ])

        #expect(read.flatMap(\.workouts).map(\.kind) == [.walk])
    }

    @Test func anACKTimeoutLeavesTheSessionOpenAndIsNotAnswered() throws {
        var processor = HealthDataLoggingProcessor()
        var open = [UInt8](repeating: 0, count: 29)
        open[0] = 0x01
        open[1] = 3
        open[22] = 83
        open[27] = 18
        _ = try processor.process(PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: open))

        let timeout = try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: [0x07, 3])
        )
        #expect(timeout == HealthDataLoggingResult())

        let resend: [UInt8] = [0x02, 3] + [UInt8](repeating: 0, count: 8)
            + sessionItem(type: 6, start: 1_788_340_000, duration: 1_200)
        let answer = try processor.process(
            PebbleProtocolFrame(endpoint: HealthDataLoggingCodec.endpoint, payload: resend)
        )
        #expect(answer.response == HealthDataLoggingCodec.ackFrame(sessionID: 3))
        #expect(answer.samples.flatMap(\.workouts).map(\.kind) == [.run])
    }

    /// The morning walk arrives in the morning sync and the run in the
    /// evening one: the day is the union, not whichever record came last.
    @Test func theMorningWalkSurvivesTheEveningRun() async throws {
        let fileURL = URL.temporaryDirectory.appending(path: "health-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = WatchHealthStore(fileURL: fileURL)
        let day = Date(timeIntervalSince1970: 1_788_303_600)
        let walk = WatchWorkout(start: day.addingTimeInterval(3_600), duration: 1_800, kind: .walk, steps: 2_000)
        let run = WatchWorkout(start: day.addingTimeInterval(36_000), duration: 2_400, kind: .run, steps: 4_000)
        _ = try await store.merge([WatchHealthSample(
            date: day, steps: 0, sleepMinutes: 0, workouts: [walk],
            updatedAt: day.addingTimeInterval(7_200)
        )])

        let merged = try await store.merge([WatchHealthSample(
            date: day, steps: 0, sleepMinutes: 0, workouts: [run],
            updatedAt: day.addingTimeInterval(40_000)
        )])

        #expect(try #require(merged.first).workouts == [walk, run])
    }

    /// A file written before workouts were kept still opens, with none.
    @Test func aLegacyFileDecodesWithNoWorkouts() throws {
        let json = """
        {"date":100,"steps":10,"sleepMinutes":0}
        """
        let decoded = try JSONDecoder().decode(WatchHealthSample.self, from: Data(json.utf8))

        #expect(decoded.workouts.isEmpty)
    }
}
