import SwiftUI
import PebbleProtocol

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

enum CatalogKindFilter: String, CaseIterable, Identifiable {
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

/// The app catalog, pushed from the Apps tab's plus button.
struct CatalogView: View {
    var model: AppModel
    var isImportingApplication: Bool = false
    var isImportDisabled: Bool = false
    var importApplication: (() -> Void)?
    /// Passed through to the detail screen. Reachable now that this is pushed
    /// rather than presented: the launcher line's own editor is a sheet on the
    /// applications screen, which a sheet could not have opened over.
    var editGlance: (WatchApplication) -> Void = { _ in }

    var body: some View {
        CatalogContent(
            applications: model.catalog.applications,
            state: { model.catalogInstallationState(for: $0) },
            isImportingApplication: isImportingApplication,
            isImportDisabled: isImportDisabled,
            isUpdating: model.catalog.isUpdating,
            feedback: model.catalog.feedback,
            importFeedback: model.applications.importFeedback,
            selectedSourceID: model.selectedCatalogSource.id,
            setSource: { id in await model.setCatalogSource(id) },
            searchResults: model.catalog.searchResults,
            searchQuery: model.catalog.searchQuery,
            hasMoreSearchResults: model.catalog.hasMoreSearchResults,
            isSearching: model.catalog.isSearching,
            importApplication: importApplication,
            // Awaited rather than launched, so that the pull-to-refresh
            // indicator stays up until the catalogue has actually been fetched.
            refresh: { await model.refreshCatalog() },
            search: { query, kind in await model.searchCatalog(query, kind: kind) },
            loadMoreResults: { await model.loadMoreCatalogSearchResults() },
            clearSearch: { model.clearCatalogSearch() },
            destination: { application in
                CatalogApplicationDetailView(
                    application: application,
                    model: model,
                    editGlance: editGlance
                )
            }
        )
        .task {
            await model.loadCatalog()
            if model.catalog.applications.isEmpty { await model.refreshCatalog() }
        }
    }
}

struct CatalogContent<Destination: View>: View {
    var applications: [CatalogApplication]
    var state: (CatalogApplication) -> CatalogInstallationState
    var isImportingApplication: Bool
    var isImportDisabled: Bool
    var isUpdating: Bool
    var feedback: FeatureFeedback?
    /// The answer to the `Import` button in this screen's own toolbar. Separate
    /// from `feedback`, which is the catalogue's: one is about the store, the
    /// other about a file from this phone.
    var importFeedback: FeatureFeedback?
    /// Which store is being browsed, and the way to browse another. The titles
    /// are the stores' own names, shown verbatim.
    var selectedSourceID: String = CatalogSource.pebble.id
    var setSource: @MainActor (String) async -> Void = { _ in }
    /// What the store's index answered, as against `applications`, the home
    /// feed the pickers sift. Nil until a search is submitted.
    var searchResults: [CatalogApplication]?
    var searchQuery: String = ""
    var hasMoreSearchResults: Bool = false
    var isSearching: Bool = false
    var importApplication: (() -> Void)?
    var refresh: @MainActor () async -> Void
    var search: @MainActor (String, WatchApplicationKind?) async -> Void = { _, _ in }
    var loadMoreResults: @MainActor () async -> Void = {}
    var clearSearch: @MainActor () -> Void = {}
    @ViewBuilder var destination: (CatalogApplication) -> Destination

    @State private var query = ""
    /// Nil for every category.
    ///
    /// A missing value rather than a sentinel string. It was `"All"`, doing
    /// three jobs at once — the row's label, the initial selection and the
    /// "do not filter" mark — so it showed in English on a Japanese screen,
    /// because `Text(_:)` given a `String` is the overload that does not
    /// localize. And a category actually named All, which the store is free to
    /// send, would have been the one category impossible to filter by.
    ///
    /// The value is always the store's own string; only the pixels are
    /// translated, by `catalogCategoryText`.
    @State private var category: String?
    @State private var kind: CatalogKindFilter = .all

    // Pushed onto the applications screen's stack rather than presented, so
    // there is no stack of its own to start and no size to ask for.
    var body: some View {
        catalogList
    }

    private var catalogList: some View {
        List {
            // The catalogue's own answers used to have nowhere to go: a pull
            // to refresh wrote to `catalog.feedback`, which only an
            // application's detail screen showed — so the refresh said
            // nothing here and then spoke up on the next screen opened.
            FeedbackBanner(feedback: feedback)
            // The import's own answer, which used to be drawn on the screen
            // this one is pushed over: the spinner in the toolbar stopped and
            // a failure was left where the reader was not looking (#110).
            FeedbackBanner(feedback: importFeedback)
            // The store's whole inventory, as against the home feed: the feed
            // is a shop window, and the search box alone only sifts what the
            // window happens to hold. While a search is on screen the feed is
            // not — the results are the answer to the question just asked, and
            // the window would only bury them.
            if let searchResults {
                Section("Store Search") {
                    if searchResults.isEmpty {
                        Text("The store found nothing for \u{201C}\(searchQuery)\u{201D}.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(searchResults) { application in
                        NavigationLink {
                            destination(application)
                        } label: {
                            CatalogApplicationRow(application: application, state: state(application))
                        }
                    }
                    if isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if hasMoreSearchResults {
                        Button("Load More") {
                            Task { await loadMoreResults() }
                        }
                    }
                }
            } else if isSearching {
                // The first page is still on its way; once it lands the
                // Store Search section above takes over.
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else {
                Section("Browse") {
                    Picker("Store", selection: Binding(
                        get: { selectedSourceID },
                        set: { id in Task { await setSource(id) } }
                    )) {
                        ForEach(CatalogSource.builtIn) { source in
                            Text(verbatim: source.title).tag(source.id)
                        }
                    }
                    Picker("Type", selection: $kind) {
                        ForEach(CatalogKindFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Category", selection: $category) {
                        // `String?.none` rather than a word standing in for
                        // "no filter".
                        Text("All Categories").tag(String?.none)
                        ForEach(categories, id: \.self) {
                            catalogCategoryText($0).tag(String?.some($0))
                        }
                    }
                }
                Section("Applications") {
                    ForEach(filteredApplications) { application in
                        NavigationLink {
                            destination(application)
                        } label: {
                            CatalogApplicationRow(application: application, state: state(application))
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: Text("Search the Store"))
        .onSubmit(of: .search) {
            Task { await search(query, searchKind) }
        }
        .onChange(of: query) { _, changed in
            // An emptied search box is the reader done with the results; typed
            // words only sift the feed until they are submitted again.
            if changed.trimmingCharacters(in: .whitespaces).isEmpty { clearSearch() }
        }
        .navigationTitle(Text("Catalog"))
        // A second pull while one is running is the model's to ignore, which
        // it does — `updateCatalog` returns early when it is already updating.
        .refreshable { await refresh() }
        .toolbar {
            // No way out of its own: the back button of the stack it was
            // pushed onto is the way out.
            ToolbarItemGroup(placement: .primaryAction) {
                if let importApplication {
                    if isImportingApplication {
                        ProgressView()
                            .accessibilityLabel(Text("Importing Pebble application"))
                    } else {
                        Button("Import", systemImage: "square.and.arrow.down", action: importApplication)
                            .accessibilityHint(Text("Choose a PBW package from Files"))
                            .disabled(isImportDisabled)
                    }
                }
            }
        }
        #if os(iOS)
        // Pushed from the Apps tab, and what is on screen is the catalogue
        // rather than the tabs.
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .overlay {
            if filteredApplications.isEmpty && searchResults == nil && !isSearching {
                // Two causes, and the screen cannot tell them apart: a filter
                // that excludes everything, or a catalogue that was never
                // fetched. Saying both beats naming the wrong one — and it
                // used to name a setting that no longer exists.
                ContentUnavailableView(
                    "No Catalog Apps",
                    systemImage: "bag",
                    description: Text("Nothing matches, or the catalog could not be fetched.")
                )
            }
        }
    }

    private var filteredApplications: [CatalogApplication] {
        CatalogFilter(category: category, kind: kind).applied(to: applications)
    }

    private var categories: [String] {
        CatalogFilter.categories(in: applications)
    }

    /// The kind picker's word for the index's tags. "All" is no tag: the index
    /// is asked for both kinds rather than neither.
    private var searchKind: WatchApplicationKind? {
        switch kind {
        case .all: nil
        case .watchapps: .watchapp
        case .watchfaces: .watchface
        }
    }
}

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
    /// Nil for every category.
    var category: String?
    var kind: CatalogKindFilter = .all

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

struct CatalogApplicationRow: View {
    var application: CatalogApplication
    var state: CatalogInstallationState

    /// A watchface's first screenshot is the face itself, which no icon says
    /// as well; a watch app's icon is its identity, so it stays first there.
    private var imageURL: URL? {
        application.kind == .watchface
            ? application.screenshotURLs.first ?? application.iconURL
            : application.iconURL ?? application.screenshotURLs.first
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: {
                Image(systemName: application.kind == .watchface ? "clock" : "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 50)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name).font(.headline)
                Text("\(application.developer) · \(application.version)").foregroundStyle(.secondary)
                // Left out where the store did not name one, as the detail
                // screen already does. It used to draw the model's `"Other"`,
                // which was this app putting a word in the store's mouth.
                if let category = application.category {
                    catalogCategoryText(category).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            CatalogStateLabel(state: state)
        }
        .frame(minHeight: 52)
    }
}

struct CatalogStateLabel: View {
    var state: CatalogInstallationState
    var body: some View {
        switch state {
        case .available: EmptyView()
        case .installed: Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        case .updateAvailable: Label("Update", systemImage: "arrow.down.circle").foregroundStyle(.tint)
        case .incompatible: Label("Incompatible", systemImage: "nosign").foregroundStyle(.secondary)
        }
    }
}

#Preview("Catalog rows") {
    List {
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .available)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .installed)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .updateAvailable)
        CatalogApplicationRow(application: PreviewSamples.catalogApplication, state: .incompatible)
        // The store did not name a category for this one. The line goes rather
        // than being filled with a word the store never said.
        CatalogApplicationRow(
            application: {
                var uncategorised = PreviewSamples.catalogApplication
                uncategorised.category = nil
                return uncategorised
            }(),
            state: .available
        )
    }
}

#Preview("Catalog") {
    CatalogContent(
        applications: [PreviewSamples.catalogApplication],
        state: { _ in .updateAvailable },
        isImportingApplication: false,
        isImportDisabled: false,
        isUpdating: false,
        feedback: nil,
        importApplication: {},
        refresh: {},
        destination: { application in Text(verbatim: application.name) }
    )
}

#Preview("Empty catalog") {
    CatalogContent(
        applications: [],
        state: { _ in .available },
        isImportingApplication: true,
        isImportDisabled: true,
        isUpdating: true,
        feedback: .failure("Catalog refresh failed; showing the offline cache."),
        importApplication: {},
        refresh: {},
        destination: { _ in EmptyView() }
    )
}

#Preview("A file that could not be imported") {
    // The two banners together, because they are two different subjects: the
    // store could not be reached, and the file the reader picked was refused.
    CatalogContent(
        applications: [PreviewSamples.catalogApplication],
        state: { _ in .available },
        isImportingApplication: false,
        isImportDisabled: false,
        isUpdating: false,
        feedback: .failure("Catalog refresh failed; showing the offline cache."),
        importFeedback: .failure("The package is not built for any connected watch."),
        importApplication: {},
        refresh: {},
        destination: { _ in EmptyView() }
    )
}
