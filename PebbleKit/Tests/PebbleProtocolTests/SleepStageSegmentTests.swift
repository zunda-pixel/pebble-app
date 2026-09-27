import Foundation
import Testing
@testable import PebbleProtocol

/// A session cut for export: the firmware tells a restful stretch twice — once
/// as itself and once inside its sleep container — and writing both as they
/// are would double-count the night.
@Suite
struct SleepStageSegmentTests {
    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(minutes * 60))
    }

    private func interval(_ from: Int, _ to: Int, deep: Bool = false) -> SleepInterval {
        SleepInterval(start: date(from), duration: TimeInterval((to - from) * 60), isDeep: deep)
    }

    /// The canonical night: one container, one deep stretch inside it.
    @Test func aDeepStretchSplitsItsContainerWithoutDoubleCounting() {
        let session = SleepSessions.grouped([
            interval(0, 480),
            interval(120, 180, deep: true),
        ]).first!

        let segments = session.stageSegments

        #expect(segments == [
            SleepStageSegment(start: date(0), end: date(120), isDeep: false),
            SleepStageSegment(start: date(120), end: date(180), isDeep: true),
            SleepStageSegment(start: date(180), end: date(480), isDeep: false),
        ])
        // No minute is told twice: the pieces add back up to the container.
        let total = segments.reduce(TimeInterval(0)) { $0 + $1.end.timeIntervalSince($1.start) }
        #expect(total == 480 * 60)
    }

    @Test func twoDeepStretchesLeaveThreeLightPieces() {
        let session = SleepSessions.grouped([
            interval(0, 400),
            interval(60, 90, deep: true),
            interval(200, 260, deep: true),
        ]).first!

        let light = session.stageSegments.filter { !$0.isDeep }
        let deep = session.stageSegments.filter(\.isDeep)

        #expect(light.map { ($0.start, $0.end) }.count == 3)
        #expect(deep.count == 2)
        #expect(light.first?.end == date(60))
        #expect(light.last?.start == date(260))
    }

    /// A session from a file written before intervals were kept: the deep
    /// minutes' positions are unknown, and inventing them would be worse than
    /// one honest light block.
    @Test func aSessionWithoutIntervalsIsOneLightBlock() {
        let session = SleepSession(start: date(0), end: date(480), asleep: 480 * 60, deep: 60 * 60)

        #expect(session.stageSegments == [
            SleepStageSegment(start: date(0), end: date(480), isDeep: false)
        ])
    }
}
