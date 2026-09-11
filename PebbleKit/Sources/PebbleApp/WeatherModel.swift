public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The places whose forecasts the watch is given, and the forecasts themselves.
@MainActor
@Observable
public final class WeatherModel {
    public internal(set) var places: [WeatherPlace] = []
    public internal(set) var reports: [WeatherReport] = []
    /// WeatherKit requires its attribution to be shown wherever its data is.
    public internal(set) var credit: WeatherCredit?
    public internal(set) var updated: Date?
    /// The record carries no unit, so the watch shows whichever number it was
    /// given: this decides which one that is.
    public internal(set) var usesFahrenheit = false
    public internal(set) var isRefreshing = false
    /// The refresh in flight, if one is. The foreground handler, the periodic
    /// loop and the screen's pull can all ask at once; the extras join this
    /// instead of fetching every place again and writing every watch twice.
    var refreshTask: Task<Void, Never>?
    public internal(set) var feedback: FeatureFeedback?
}
