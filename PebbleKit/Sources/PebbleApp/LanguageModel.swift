// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// Which language the watch shows its own text in.
@MainActor
@Observable
public final class LanguageModel {
    public internal(set) var isInstalling = false
    public internal(set) var feedback: FeatureFeedback?
}
