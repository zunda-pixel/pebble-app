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

    /// What the store said about applications already in the library, keyed by
    /// the identifier their package carries.
    ///
    /// Held apart from `applications` because these did not come from the
    /// feed: each was asked for one at a time, by an installed application's
    /// own UUID, to show its detail screen.
    public internal(set) var storeEntries: [UUID: CatalogApplication] = [:]

    /// Which of those have been asked about at all — including the ones the
    /// store does not have, so that a package it never listed is not asked
    /// after again on every visit.
    public internal(set) var answeredStoreLookups: Set<UUID> = []
}
