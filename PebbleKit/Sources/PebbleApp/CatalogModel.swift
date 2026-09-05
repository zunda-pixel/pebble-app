public import PebbleProtocol
public import Foundation
// The `@Observable` macro writes a public conformance on a public class, so
// the module that declares the protocol has to be imported publicly too.
public import Observation

/// The remote catalogue of watch apps, and what is being installed from it.
@MainActor
@Observable
public final class CatalogModel {
    public internal(set) var applications: [CatalogApplication] = []
    public internal(set) var lastUpdated: Date?
    public internal(set) var isUpdating = false
    public internal(set) var installingApplicationID: UUID?
    public internal(set) var feedback: FeatureFeedback?
}
