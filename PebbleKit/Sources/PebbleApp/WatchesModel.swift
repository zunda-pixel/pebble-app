public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The watches this phone knows about, whether or not one is connected now.
///
/// The live link is `AppModel`'s: which watch is connected, what is being
/// scanned for, why the last attempt failed. This is the remembered part.
@MainActor
@Observable
public final class WatchesModel {
    public internal(set) var saved: [SavedWatch] = []
    public internal(set) var unknownBonded: [UnknownBondedWatch] = []
    public internal(set) var feedback: FeatureFeedback?
    /// What each watch was last told to do to itself, until it comes back. A
    /// restart says nothing on its way out and nothing on its way in, so the
    /// only news the reader gets is the link returning.
    public internal(set) var resetFeedback: [WatchID: FeatureFeedback] = [:]
}
