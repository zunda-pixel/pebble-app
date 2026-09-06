import SwiftUI
import PebbleProtocol

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

enum CatalogSort: String, CaseIterable, Identifiable {
    case name, category, version
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .name: "Name"
        case .category: "Category"
        case .version: "Version"
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
            importApplication: importApplication,
            installUpdates: { Task { await model.installCatalogUpdates() } },
            // Awaited rather than launched, so that the pull-to-refresh
            // indicator stays up until the catalogue has actually been fetched.
            refresh: { await model.refreshCatalog() },
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
    var importApplication: (() -> Void)?
    var installUpdates: () -> Void
    var refresh: @MainActor () async -> Void
    @ViewBuilder var destination: (CatalogApplication) -> Destination

    @State private var query = ""
    @State private var category = "All"
    @State private var kind: CatalogKindFilter = .all
    @State private var sort: CatalogSort = .name

    // Pushed onto the applications screen's stack rather than presented, so
    // there is no stack of its own to start and no size to ask for.
    var body: some View {
        catalogList
    }

    private var catalogList: some View {
        List {
            Section("Browse") {
                Picker("Type", selection: $kind) {
                    ForEach(CatalogKindFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                Picker("Sort", selection: $sort) {
                    ForEach(CatalogSort.allCases) { Text($0.title).tag($0) }
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
        .searchable(text: $query)
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
                Button("Update All", systemImage: "arrow.down.app", action: installUpdates)
                #if os(macOS)
                // Kept here alone: `refreshable` is a gesture the phone has
                // and a window does not, so dropping the button would leave
                // the Mac with no way to fetch the catalogue at all.
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isUpdating)
                #endif
            }
        }
        #if os(iOS)
        // Pushed from the Apps tab, and what is on screen is the catalogue
        // rather than the tabs.
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .overlay {
            if filteredApplications.isEmpty {
                ContentUnavailableView("No Catalog Apps", systemImage: "bag", description: Text("Catalog sources can be added in Settings."))
            }
        }
    }

    private var filteredApplications: [CatalogApplication] {
        let filtered = applications.filter { application in
            let matchesQuery = query.isEmpty
                || application.name.localizedCaseInsensitiveContains(query)
                || application.developer.localizedCaseInsensitiveContains(query)
                || application.summary.localizedCaseInsensitiveContains(query)
            let matchesCategory = category == "All" || application.category == category
            let matchesKind = kind == .all
                || (kind == .watchapps && application.kind == .watchapp)
                || (kind == .watchfaces && application.kind == .watchface)
            return matchesQuery && matchesCategory && matchesKind
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .name: lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            case .category: lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            case .version: lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
            }
        }
    }

    private var categories: [String] {
        ["All"] + Set(applications.map(\.category)).sorted()
    }
}

struct CatalogApplicationRow: View {
    var application: CatalogApplication
    var state: CatalogInstallationState

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: application.iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: application.kind == .watchface ? "clock" : "square.grid.2x2")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(application.name).font(.headline)
                Text("\(application.developer) · \(application.version)").foregroundStyle(.secondary)
                Text(application.category).font(.caption).foregroundStyle(.secondary)
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
    }
}

#Preview("Catalog") {
    CatalogContent(
        applications: [PreviewSamples.catalogApplication],
        state: { _ in .updateAvailable },
        isImportingApplication: false,
        isImportDisabled: false,
        isUpdating: false,
        importApplication: {},
        installUpdates: {},
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
        importApplication: {},
        installUpdates: {},
        refresh: {},
        destination: { _ in EmptyView() }
    )
}
