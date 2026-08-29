import SwiftUI
import API

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

/// The app catalog, presented as a sheet from the Apps tab's plus button.
struct CatalogView: View {
    var model: AppModel
    var isImportingApplication: Bool = false
    var isImportDisabled: Bool = false
    var importApplication: (() -> Void)?
    @State private var query = ""
    @State private var category = "All"
    @State private var kind: CatalogKindFilter = .all
    @State private var sort: CatalogSort = .name
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            catalogList
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
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
                        CatalogApplicationDetailView(application: application, model: model)
                    } label: {
                        CatalogApplicationRow(
                            application: application,
                            state: model.catalogInstallationState(for: application)
                        )
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Catalog")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItemGroup {
                if let importApplication {
                    if isImportingApplication {
                        ProgressView()
                            .accessibilityLabel("Importing Pebble application")
                    } else {
                        Button("Import", systemImage: "square.and.arrow.down", action: importApplication)
                            .accessibilityHint("Choose a PBW package from Files")
                            .disabled(isImportDisabled)
                    }
                }
                Button("Update All", systemImage: "arrow.down.app") {
                    Task { await model.installCatalogUpdates() }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshCatalog() }
                }
                .disabled(model.isUpdatingCatalog)
            }
        }
        .overlay {
            if filteredApplications.isEmpty {
                ContentUnavailableView("No Catalog Apps", systemImage: "bag", description: Text("Catalog sources can be added in Settings."))
            }
        }
        .task {
            await model.loadCatalog()
            if model.catalogApplications.isEmpty { await model.refreshCatalog() }
        }
    }

    private var filteredApplications: [PebbleCatalogApplication] {
        let filtered = model.catalogApplications.filter { application in
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
        ["All"] + Set(model.catalogApplications.map(\.category)).sorted()
    }
}

struct CatalogApplicationRow: View {
    var application: PebbleCatalogApplication
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

struct CatalogApplicationDetailView: View {
    var application: PebbleCatalogApplication
    var model: AppModel

    var body: some View {
        List {
            Section {
                CatalogApplicationRow(
                    application: application,
                    state: model.catalogInstallationState(for: application)
                )
                if !application.summary.isEmpty { Text(application.summary) }
            }
            if !application.screenshotURLs.isEmpty {
                Section("Screenshots") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(application.screenshotURLs, id: \.self) { url in
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 220, height: 220)
                                .accessibilityLabel("Screenshot of \(application.name)")
                            }
                        }
                    }
                }
            }
            Section("Compatibility") {
                Text(application.supportedPlatforms.sorted().joined(separator: ", "))
            }
            if let releaseNotes = application.releaseNotes, !releaseNotes.isEmpty {
                Section("Release Notes") { Text(releaseNotes) }
            }
            Section {
                Button(installButtonTitle, systemImage: "arrow.down.app") {
                    Task { await model.installCatalogApplication(application) }
                }
                .disabled(!canInstall || model.installingCatalogApplicationID != nil)
                if model.installingCatalogApplicationID == application.id { ProgressView() }
                if let message = model.dataSyncStatusMessage { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(application.name)
    }

    private var state: CatalogInstallationState { model.catalogInstallationState(for: application) }
    private var canInstall: Bool { state == .available || state == .updateAvailable }
    private var installButtonTitle: LocalizedStringKey { state == .updateAvailable ? "Update" : "Install" }
}
