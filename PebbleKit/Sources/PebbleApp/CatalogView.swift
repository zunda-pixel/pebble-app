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

/// The app catalog, presented as a sheet from the Apps tab's plus button.
struct CatalogView: View {
    var model: AppModel
    var isImportingApplication: Bool = false
    var isImportDisabled: Bool = false
    var importApplication: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CatalogContent(
            applications: model.catalog.applications,
            state: { model.catalogInstallationState(for: $0) },
            isImportingApplication: isImportingApplication,
            isImportDisabled: isImportDisabled,
            isUpdating: model.catalog.isUpdating,
            importApplication: importApplication,
            installUpdates: { Task { await model.installCatalogUpdates() } },
            refresh: { Task { await model.refreshCatalog() } },
            close: { dismiss() },
            destination: { application in
                CatalogApplicationDetailView(application: application, model: model)
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
    var refresh: () -> Void
    var close: () -> Void
    @ViewBuilder var destination: (CatalogApplication) -> Destination

    @State private var query = ""
    @State private var category = "All"
    @State private var kind: CatalogKindFilter = .all
    @State private var sort: CatalogSort = .name

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
                        destination(application)
                    } label: {
                        CatalogApplicationRow(application: application, state: state(application))
                    }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(Text("Catalog"))
        .toolbar {
            Button(role: .close, action: close)
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
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .disabled(isUpdating)
        }
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

struct CatalogApplicationDetailView: View {
    var application: CatalogApplication
    var model: AppModel

    var body: some View {
        CatalogApplicationDetailContent(
            application: application,
            state: model.catalogInstallationState(for: application),
            isInstalling: model.catalog.installingApplicationID == application.id,
            isAnyInstallRunning: model.catalog.installingApplicationID != nil,
            feedback: model.catalog.feedback,
            install: { Task { await model.installCatalogApplication(application) } }
        )
    }
}

struct CatalogApplicationDetailContent: View {
    var application: CatalogApplication
    var state: CatalogInstallationState
    var isInstalling: Bool
    var isAnyInstallRunning: Bool
    var feedback: FeatureFeedback?
    var install: () -> Void

    var body: some View {
        List {
            Section {
                CatalogApplicationRow(application: application, state: state)
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
                                .accessibilityLabel(Text("Screenshot of \(application.name)"))
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
                Button(installButtonTitle, systemImage: "arrow.down.app", action: install)
                    .disabled(!canInstall || isAnyInstallRunning)
                if isInstalling { ProgressView() }
                FeedbackBanner(feedback: feedback)
            }
        }
        .navigationTitle(application.name)
    }

    private var canInstall: Bool { state == .available || state == .updateAvailable }
    private var installButtonTitle: LocalizedStringKey { state == .updateAvailable ? "Update" : "Install" }
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
        close: {},
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
        close: {},
        destination: { _ in EmptyView() }
    )
}

#Preview("Catalog app") {
    NavigationStack {
        CatalogApplicationDetailContent(
            application: PreviewSamples.catalogApplication,
            state: .available,
            isInstalling: false,
            isAnyInstallRunning: false,
            feedback: nil,
            install: {}
        )
    }
}
