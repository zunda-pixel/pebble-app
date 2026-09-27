import SwiftUI

/// The store's category, in the reader's language where this app knows the
/// name and as the store said it where it does not — a category added upstream
/// shows up untranslated rather than not at all. Filtering and sorting still
/// use the store's own string; only the pixels change.
///
/// The known names are the store's current five (measured against both home
/// feeds, 2026-09-11) and the classic store's Notifications and Remotes, which
/// the Rebble feed still uses.
func catalogCategoryText(_ category: String) -> Text {
    switch category {
    case "Daily": Text("Daily")
    case "Faces": Text("Faces")
    case "Games": Text("Games")
    case "Health & Fitness": Text("Health & Fitness")
    case "Tools & Utilities": Text("Tools & Utilities")
    case "Notifications": Text("Notifications")
    case "Remotes": Text("Remotes")
    default: Text(verbatim: category)
    }
}

/// The store's shelf, in the reader's language where this app knows the name
/// and as the store said it where it does not — the same bargain as
/// `catalogCategoryText` above. The known names are both homes' current four
/// (measured 2026-09-21): Top Picks and Generated Watchfaces exist only on the
/// faces home, Most Loved on both, and `all` names its kind.
func catalogCollectionText(_ name: String) -> Text {
    switch name {
    case "Top Picks (Changes Daily)": Text("Top Picks (Changes Daily)")
    case "Most Loved": Text("Most Loved")
    case "All Watchapps": Text("All Watchapps")
    case "All Watchfaces": Text("All Watchfaces")
    case "Generated Watchfaces": Text("Generated Watchfaces")
    default: Text(verbatim: name)
    }
}
