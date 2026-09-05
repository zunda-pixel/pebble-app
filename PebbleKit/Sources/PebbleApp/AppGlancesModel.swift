public import PebbleProtocol
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The line each watchapp shows in the launcher, for the apps that have one.
@MainActor
@Observable
public final class AppGlancesModel {
    public internal(set) var glances: [AppGlance] = []
}
