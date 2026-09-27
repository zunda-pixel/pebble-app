import SwiftUI
import PebbleProtocol

struct ApplicationsView: View {
    var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var isChoosingPackage = false
    @State private var selectedWatchID: WatchID?
    @State private var glanceApplication: WatchApplication?

    // The picked watch while it stays connected, otherwise the primary one.
    private var displayedWatchID: WatchID? {
        if let selectedWatchID,
           model.connectedWatches.contains(where: { $0.id == selectedWatchID }) {
            return selectedWatchID
        }
        return model.connectedWatch?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.connectedWatches.count > 1 {
                Picker("Watch", selection: Binding(
                    get: { displayedWatchID },
                    set: { selectedWatchID = $0 }
                )) {
                    ForEach(model.connectedWatches) { watch in
                        Text(watch.name).tag(watch.id)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            applicationsContent
        }
        .sheet(item: $glanceApplication) { application in
            AppGlanceView(model: model, application: application)
        }
    }

    /// What the watch on screen is being sent, if anything. A transfer to another
    /// watch is that watch's to show.
    private var transfer: ApplicationTransfer? {
        displayedWatchID.flatMap { model.applicationTransfer(on: $0) }
    }

    private var applicationsContent: some View {
        ApplicationsContent(
            watchApplications: model.applications.apps,
            watchfaces: model.applications.watchfaces,
            activeWatchfaceID: model.applications.activeWatchfaceID(on: displayedWatchID),
            installedApplicationIDs: displayedWatchID.map { model.installedApplicationIDs(on: $0) },
            isLoading: model.applications.isLoading,
            libraryFeedback: model.applications.libraryFeedback,
            operationFeedback: model.applications.managementFeedback,
            importFeedback: model.applications.importFeedback,
            isOperationInProgress: model.isApplicationManagementBusy,
            installingApplicationName: transfer?.name,
            installationProgress: transfer?.progress,
            // The pull is the phone's Update All: check the store and install
            // whatever is newer.
            refresh: { await model.installCatalogUpdates() },
            // The store's picture of an installed application, the same way
            // the catalog rows choose theirs: a watchface is its screenshot,
            // an app its icon.
            storeImageURL: { application in
                guard let entry = await model.storeEntry(for: application.id) else { return nil }
                return application.kind == .watchface
                    ? entry.screenshotURLs.first ?? entry.iconURL
                    : entry.iconURL ?? entry.screenshotURLs.first
            },
            removeApplication: { applicationID in
                Task { await model.removeApplication(id: applicationID) }
            },
            // One task, each removal awaited before the next: a task apiece
            // started them all at once, and every one after the first was
            // refused as another operation already in progress.
            removeApplications: { applicationIDs in
                Task {
                    var removed = 0
                    for applicationID in applicationIDs {
                        if await model.removeApplication(id: applicationID) { removed += 1 }
                    }
                    await DiagnosticLog.shared.record(
                        .info,
                        category: "application",
                        message: "Removed \(removed) of \(applicationIDs.count) selected application(s)"
                    )
                }
            },
            reorderApplications: { kind, offsets, destination in
                Task {
                    await model.reorderApplications(
                        kind: kind,
                        fromOffsets: offsets,
                        toOffset: destination
                    )
                }
            },
            configureApplication: { application in
                Task { await model.configureApplication(application) }
            },
            editGlance: { application in glanceApplication = application },
            activateWatchface: { application in
                Task { await model.activateWatchface(application) }
            },
            detail: { application in
                ApplicationDetailView(
                    model: model,
                    application: application,
                    watchID: displayedWatchID,
                    editGlance: { glanceApplication = $0 }
                )
            }
        )
        .navigationTitle(Text("Apps"))
        .task {
            await model.loadApplications()
            // The cached catalogue, read off disk without asking the network,
            // so that Update All below knows whether there is anything to
            // update before the catalogue screen has ever been opened.
            await model.loadCatalog()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    CatalogView(
                        model: model,
                        isImportingApplication: model.applications.isImporting,
                        isImportDisabled: model.isApplicationManagementBusy,
                        importApplication: { isChoosingPackage = true },
                        editGlance: { glanceApplication = $0 }
                    )
                } label: {
                    Label("Add App", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isChoosingPackage,
            allowedContentTypes: [.pebblePackage]
        ) { result in
            guard case .success(let url) = result else {
                return
            }
            Task { await model.importApplication(from: url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let packageURL = urls.first(where: { $0.pathExtension.lowercased() == "pbw" }) else {
                return false
            }
            Task { await model.importApplication(from: packageURL) }
            return true
        }
        // By the page rather than by whether one is showing: the web view was
        // built twice for one opening under a `Bool` and an `if let` inside,
        // because nothing tied the sheet's contents to the page they were for.
        .sheet(item: Binding(
            get: { model.applications.configurationPage },
            set: { page in
                if page == nil { Task { await model.closeConfiguration() } }
            }
        )) { page in
            NavigationStack {
                ConfigurationWebView(url: page.url) { response in
                    Task { await model.closeConfiguration(response: response) }
                }
                .navigationTitle(
                    model.applications.configurationApplication.map { Text(verbatim: $0.displayName) }
                        ?? Text("App Settings")
                )
                .toolbar {
                    // Closing, not confirming: the page has its own submit,
                    // and whatever it posted has already been applied by
                    // the time this is reachable.
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            Task { await model.closeConfiguration() }
                        }
                    }
                }
            }
        }
    }
}

struct ApplicationsContent<Detail: View>: View {
    var watchApplications: [WatchApplication]
    var watchfaces: [WatchApplication]
    var activeWatchfaceID: UUID?
    /// Nil when no watch is connected: install state is unknown, not shown.
    var installedApplicationIDs: Set<UUID>?
    var isLoading: Bool
    var libraryFeedback: FeatureFeedback?
    var operationFeedback: FeatureFeedback?
    var importFeedback: FeatureFeedback?
    var isOperationInProgress: Bool
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var refresh: @MainActor () async -> Void = {}
    var storeImageURL: (WatchApplication) async -> URL? = { _ in nil }
    var removeApplication: (UUID) -> Void
    var removeApplications: ([UUID]) -> Void
    var reorderApplications: (WatchApplicationKind, IndexSet, Int) -> Void
    var configureApplication: (WatchApplication) -> Void
    var editGlance: (WatchApplication) -> Void
    var activateWatchface: (WatchApplication) -> Void
    @ViewBuilder var detail: (WatchApplication) -> Detail

    @State private var applicationToRemove: WatchApplication?
    /// The rows ticked in edit mode, by application id, for a delete that takes
    /// several at once.
    @State private var selection = Set<UUID>()
    @State private var isConfirmingBulkRemoval = false
    /// What was ticked when Remove was tapped. The alert's own button reads it
    /// rather than `selection`, which the list may have emptied by the time the
    /// alert is answered — the confirmed removal then removed nothing.
    @State private var applicationsToRemove: [UUID] = []
    /// Sifts the library in place. The catalog's search box asks the store;
    /// this one only narrows what is already here.
    @State private var query = ""

    var body: some View {
        if isLoading && watchApplications.isEmpty && watchfaces.isEmpty {
            List(0..<3, id: \.self) { _ in
                ApplicationPlaceholderRow()
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel(Text("Loading apps"))
        } else if watchApplications.isEmpty && watchfaces.isEmpty {
            ContentUnavailableView(
                "No Apps",
                systemImage: "square.grid.2x2",
                description: Text("Imported watch apps and watchfaces will appear here.")
            )
        } else {
            // Above the list rather than in it. These arrive with the very
            // operation that removes an application, so a removal used to insert
            // a section at the top of the list in the same update that deleted
            // a row from it — which UIKit would not reconcile: it threw an
            // invalid-update exception rather than drawing.
            VStack(spacing: 0) {
                ApplicationOperationBanner(
                    operationFeedback: operationFeedback,
                    installingApplicationName: installingApplicationName,
                    installationProgress: installationProgress,
                    libraryFeedback: libraryFeedback,
                    importFeedback: importFeedback
                )
                List(selection: $selection) {
                    // Each section carries the kind it is for as its identity.
                    // Written as two `if`s, removing the last watch app left the
                    // watchfaces standing where the watch apps had been, and
                    // SwiftUI told UIKit a row had gone from a section that
                    // still had one — which UIKit threw over. A section that can
                    // be told apart moves instead of being rewritten.
                    ForEach(groups) { group in
                        ApplicationSection(
                            title: group.title,
                            applications: group.applications,
                            activeWatchfaceID: activeWatchfaceID,
                            installedApplicationIDs: installedApplicationIDs,
                            isOperationInProgress: isOperationInProgress,
                            // A row's offsets in a sifted list are not its
                            // offsets in the whole one, and the launcher order
                            // is the whole one's.
                            isFiltering: !trimmedQuery.isEmpty,
                            storeImageURL: storeImageURL,
                            requestRemoval: { applicationToRemove = $0 },
                            configureApplication: configureApplication,
                            editGlance: editGlance,
                            activateWatchface: activateWatchface,
                            moveApplications: { offsets, destination in
                                reorderApplications(group.kind, offsets, destination)
                            },
                            detail: detail
                        )
                    }
                }
                .searchable(text: $query)
                // Awaited so the indicator stays up until the store has been
                // asked and any updates are on their way.
                .refreshable { await refresh() }
                // An alert, and one for the whole list rather than one per row:
                // a dialog per row meant the second row asked about was refused
                // its own ("already presenting").
                .alert(
                    Text("Remove \(applicationToRemove?.displayName ?? "")?"),
                    isPresented: Binding(
                        get: { applicationToRemove != nil },
                        set: { presented in
                            if !presented { applicationToRemove = nil }
                        }
                    ),
                    presenting: applicationToRemove
                ) { application in
                    Button("Remove App", role: .destructive) {
                        removeApplication(application.id)
                    }
                    Button(role: .cancel) {}
                } message: { _ in
                    Text("The app and its settings will be removed. A Pebble that is not connected is told the next time it is.")
                }
                // A second alert, for the several ticked in edit mode at once.
                .alert(
                    Text("Remove \(applicationsToRemove.count) selected?"),
                    isPresented: $isConfirmingBulkRemoval
                ) {
                    Button("Remove", role: .destructive) {
                        removeApplications(applicationsToRemove)
                        applicationsToRemove = []
                        selection.removeAll()
                    }
                    Button(role: .cancel) {}
                } message: {
                    Text("The apps and their settings will be removed. A Pebble that is not connected is told the next time it is.")
                }
                .toolbar {
                    // The watch's launcher order is what reorder edits, so editing
                    // is where both multi-select and drag-to-reorder live.
                    #if os(iOS)
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                    #endif
                    if !selection.isEmpty {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove Selected", systemImage: "trash", role: .destructive) {
                                applicationsToRemove = Array(selection)
                                isConfirmingBulkRemoval = true
                            }
                            .disabled(isOperationInProgress)
                        }
                    }
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groups: [ApplicationGroup] {
        [
            ApplicationGroup(kind: .watchapp, title: "Watch Apps", applications: sifted(watchApplications)),
            ApplicationGroup(kind: .watchface, title: "Watchfaces", applications: sifted(watchfaces)),
        ]
        .filter { !$0.applications.isEmpty }
    }

    private func sifted(_ applications: [WatchApplication]) -> [WatchApplication] {
        let words = trimmedQuery
        guard !words.isEmpty else { return applications }
        return applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(words)
                || $0.companyName.localizedCaseInsensitiveContains(words)
        }
    }
}

/// One of the list's sections, as something the list can tell apart from the
/// other by what it holds rather than by where it sits.
private struct ApplicationGroup: Identifiable {
    var kind: WatchApplicationKind
    var title: LocalizedStringKey
    var applications: [WatchApplication]

    var id: WatchApplicationKind { kind }
}

#Preview("Library") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: PreviewSamples.watchApplications,
            watchfaces: PreviewSamples.watchfaces,
            activeWatchfaceID: PreviewSamples.watchfaces.first?.id,
            installedApplicationIDs: Set(PreviewSamples.watchApplications.prefix(1).map(\.id)),
            isLoading: false,
            libraryFeedback: nil,
            operationFeedback: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            removeApplications: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}

#Preview("Installing") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: PreviewSamples.watchApplications,
            watchfaces: [],
            activeWatchfaceID: nil,
            installedApplicationIDs: nil,
            isLoading: false,
            libraryFeedback: nil,
            operationFeedback: .progress("Sending Timeline Weather to Pebble 5209."),
            isOperationInProgress: true,
            installingApplicationName: "Timeline Weather",
            installationProgress: PreviewSamples.transferProgress,
            removeApplication: { _ in },
            removeApplications: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: [],
            watchfaces: [],
            activeWatchfaceID: nil,
            installedApplicationIDs: nil,
            isLoading: false,
            libraryFeedback: nil,
            operationFeedback: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            removeApplications: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}

#Preview("Loading") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: [],
            watchfaces: [],
            activeWatchfaceID: nil,
            installedApplicationIDs: nil,
            isLoading: true,
            libraryFeedback: nil,
            operationFeedback: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            removeApplications: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}

#Preview("An operation refused") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: PreviewSamples.watchApplications,
            watchfaces: PreviewSamples.watchfaces,
            activeWatchfaceID: PreviewSamples.watchfaces.first?.id,
            installedApplicationIDs: nil,
            isLoading: false,
            libraryFeedback: .failure("Another app operation is already in progress."),
            operationFeedback: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            removeApplications: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}
