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
    /// The feed's shelves — Top Picks, Most Loved — in the feed's own order.
    public internal(set) var collections: [CatalogCollection] = []
    /// The store being browsed, and so the one asked about any single
    /// application.
    public internal(set) var source: CatalogSource = .pebble
    public internal(set) var isUpdating = false
    public internal(set) var installingApplicationID: UUID?
    /// The catalogue's last word, and which application it was about — nil
    /// for the catalogue as a whole: a refresh, a search.
    ///
    /// The application travels with the words rather than being read off
    /// `installingApplicationID`, which is cleared the moment an install ends
    /// and so took the install's own answer off its screen with it.
    public internal(set) var report: CatalogReport?

    /// What the catalogue screen shows, whoever it was about. Setting it says
    /// something about the catalogue as a whole.
    public internal(set) var feedback: FeatureFeedback? {
        get { report?.feedback }
        set { report = newValue.map { CatalogReport(feedback: $0, applicationID: nil) } }
    }

    /// What an application's own screen shows: only what was about it.
    public func feedback(about applicationID: UUID) -> FeatureFeedback? {
        guard let report, report.applicationID == applicationID else { return nil }
        return report.feedback
    }

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

    /// What the store's own index answered, as against `applications`, which
    /// is the home feed. Nil until a search is submitted and after it is
    /// cleared, so the screen can tell "no search" from "no results".
    public internal(set) var searchResults: [CatalogApplication]?
    /// The words the results answer, kept so a changed search box does not
    /// silently relabel old results.
    public internal(set) var searchQuery = ""
    public internal(set) var hasMoreSearchResults = false
    public internal(set) var isSearching = false
    /// The next page to ask the index for.
    @ObservationIgnored var searchPage = 0
    @ObservationIgnored var searchKind: WatchApplicationKind?
}

/// Something the catalogue said, and the application it said it about.
public struct CatalogReport: Equatable {
    public var feedback: FeatureFeedback
    public var applicationID: UUID?
}
