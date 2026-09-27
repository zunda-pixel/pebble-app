public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// Steps and sleep, as the watch counted them and as HealthKit has them.
@MainActor
@Observable
public final class HealthModel {
    public internal(set) var samples: [WatchHealthSample] = []
    public internal(set) var exportURL: URL?
    public internal(set) var feedback: FeatureFeedback?
}
