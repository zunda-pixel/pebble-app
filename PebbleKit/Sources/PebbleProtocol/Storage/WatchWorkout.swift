public import Foundation
import MemberwiseInit

/// One workout the watch recorded: a significant walk, a run, or an open
/// workout started from the workout app.
///
/// The watch sends these on the same data-logging sessions as sleep, one
/// `ActivitySessionDataLoggingRecord` per finished workout — an ongoing one is
/// never sent (`activity_sessions.c`). From logging version 3 the record
/// carries what the workout cost (`ActivitySessionDataStepping` in
/// `activity.h`); an older record knows only when and how long.
@MemberwiseInit(.public)
public struct WatchWorkout: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        /// `ActivitySessionType_Walk`: a "significant" length walk.
        case walk
        /// `ActivitySessionType_Run`.
        case run
        /// `ActivitySessionType_Open`: the catch-all the workout app records.
        case open
    }

    public var start: Date
    public var duration: TimeInterval
    public var kind: Kind
    public var steps: Int = 0
    public var activeKilocalories: Int = 0
    public var restingKilocalories: Int = 0
    public var distanceMetres: Int = 0

    public var end: Date { start.addingTimeInterval(duration) }
}
