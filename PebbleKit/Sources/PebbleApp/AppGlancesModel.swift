public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The line each watchapp shows in the launcher, for the apps that have one.
@MainActor
@Observable
public final class AppGlancesModel {
    public internal(set) var glances: [AppGlance] = []

    /// What came of saving a line. The feature had no answer at all: a store
    /// that refused the line was swallowed by a `try?`, and the screen showed
    /// the same words back as though they had been kept.
    public internal(set) var feedback: FeatureFeedback?
}
