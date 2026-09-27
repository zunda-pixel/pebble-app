public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// Which language each watch shows its own text in, and the packs on their way.
///
/// By watch: one watch taking a pack is no reason to disable another's
/// buttons, nor to show its answer on another's screen.
@MainActor
@Observable
public final class LanguageModel {
    public internal(set) var installing: Set<WatchID> = []
    public internal(set) var feedback: [WatchID: FeatureFeedback] = [:]

    public func isInstalling(on watchID: WatchID) -> Bool {
        installing.contains(watchID)
    }
}
