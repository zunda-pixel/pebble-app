import SwiftUI
import PebbleProtocol

/// Which of the catalogue's applications the three pickers leave on screen.
///
/// Its own type so that the fault it was written to fix can be shown to be
/// gone. The predicate lived inside the view, where reaching it meant building
/// the view, and what it did with a category named All could only be reasoned
/// about — which is how `"All"` came to be the label, the initial selection and
/// the "do not filter" mark all at once.
///
/// No query: the search box above these pickers asks the store's index, and
/// sifting what is already on the phone is the library screen's job. No sort
/// either — name order is the only one that earned its place: version order
/// compared numbers that mean nothing across applications, and category order
/// repeated the category filter (removed 2026-09-12).
struct CatalogFilter {
    /// One of the two kinds, or both. Nested here because a bare
    /// `CatalogFilter.Kind` beside `CatalogFilter` left a reader guessing which
    /// was the general one.
    enum Kind: String, CaseIterable, Identifiable {
        case all, watchapps, watchfaces
        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .watchapps: "Watch Apps"
            case .watchfaces: "Watchfaces"
            }
        }
    }

    /// Nil for every category.
    var category: String?
    var kind: Kind = .all

    /// What the store called the applications it sent, minus the ones it did
    /// not name. "Every category" is a row above these rather than one of them,
    /// so there is nothing of this app's own in here.
    static func categories(in applications: [CatalogApplication]) -> [String] {
        Set(applications.compactMap(\.category)).sorted()
    }

    func applied(to applications: [CatalogApplication]) -> [CatalogApplication] {
        let filtered = applications.filter { application in
            let matchesCategory = category.map { application.category == $0 } ?? true
            let matchesKind = kind == .all
                || (kind == .watchapps && application.kind == .watchapp)
                || (kind == .watchfaces && application.kind == .watchface)
            return matchesCategory && matchesKind
        }
        return filtered.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
