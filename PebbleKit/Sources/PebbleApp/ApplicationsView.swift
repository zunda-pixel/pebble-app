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
            activeWatchfaceID: model.applications.activeWatchfaceID,
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
                .navigationTitle(model.applications.configurationApplication?.displayName ?? "App Settings")
                .toolbar {
                    // The leading slot, which is where a modal's way out goes
                    // on both platforms — named for cancelling, but nothing is
                    // being cancelled here.
                    ToolbarItem(placement: .cancellationAction) {
                        // Closing, not confirming: the page has its own submit,
                        // and whatever it posted has already been applied by
                        // the time this is reachable.
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
    var reorderApplications: (WatchApplicationKind, IndexSet, Int) -> Void
    var configureApplication: (WatchApplication) -> Void
    var editGlance: (WatchApplication) -> Void
    var activateWatchface: (WatchApplication) -> Void
    @ViewBuilder var detail: (WatchApplication) -> Detail

    @State private var applicationToRemove: WatchApplication?
    /// The rows ticked in edit mode, by application id, for a delete that takes
    /// several at once. Separate from the single-row swipe above.
    @State private var selection = Set<UUID>()
    @State private var isConfirmingBulkRemoval = false
    /// Sifts the library in place. The catalog's search box asks the store;
    /// this one only narrows what is already here.
    @State private var query = ""

    var body: some View {
        if isLoading && watchApplications.isEmpty && watchfaces.isEmpty {
            List(0..<3, id: \.self) { _ in
                ApplicationPlaceholderRow()
            }
            .redacted(reason: .placeholder)
            .accessibilityLabel(Text("Loading applications"))
        } else if watchApplications.isEmpty && watchfaces.isEmpty {
            ContentUnavailableView(
                "No Apps",
                systemImage: "square.grid.2x2",
                description: Text("Imported watch apps and watchfaces will appear here.")
            )
        } else {
            // Above the list rather than in it. These arrive with the very
            // operation that removes an application, so a swipe used to insert
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
                // An alert, and one for the whole list rather than one per row.
                // A confirmation dialog is anchored, and a swiped row is already
                // gone by the time it would be asked about, so there is nothing
                // left to anchor to; a dialog per row also meant the second row
                // swiped was refused its own ("already presenting").
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
                    Button("Remove Application", role: .destructive) {
                        removeApplication(application.id)
                    }
                    Button(role: .cancel) {}
                } message: { _ in
                    Text("The application and its settings will be removed. A Pebble that is not connected is told the next time it is.")
                }
                // A second alert, for the several ticked in edit mode at once.
                .alert(
                    Text("Remove \(selection.count) selected?"),
                    isPresented: $isConfirmingBulkRemoval
                ) {
                    Button("Remove", role: .destructive) {
                        for id in selection { removeApplication(id) }
                        selection.removeAll()
                    }
                    Button(role: .cancel) {}
                } message: {
                    Text("The applications and their settings will be removed. A Pebble that is not connected is told the next time it is.")
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

/// What the library is in the middle of, and what went wrong doing it.
struct ApplicationOperationBanner: View {
    var operationFeedback: FeatureFeedback?
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var libraryFeedback: FeatureFeedback?
    /// Shown here as well as on the catalogue, because a package dropped on
    /// this screen is imported by the same call as the one the catalogue's
    /// button makes.
    var importFeedback: FeatureFeedback?

    private var isEmpty: Bool {
        operationFeedback == nil && libraryFeedback == nil && importFeedback == nil
            && (installingApplicationName == nil || installationProgress == nil)
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FeedbackBanner(feedback: operationFeedback)
                if let installingApplicationName, let installationProgress {
                    // Named for the application: this screen already knows
                    // which watch, from the picker at the top. An
                    // application's own screen is the other way round and
                    // names the watch.
                    TransferProgressRow(
                        title: installingApplicationName,
                        systemImage: "arrow.down.app",
                        progress: installationProgress
                    )
                }
                FeedbackBanner(feedback: libraryFeedback)
                FeedbackBanner(feedback: importFeedback)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// One transfer, as a bar and the bytes behind it.
///
/// The title is the caller's, because the two screens that show a transfer know
/// different halves of it: the library screen has a watch picker and so names
/// the application, while an application's own screen names the watch — and
/// shows one of these per watch, since an installed application is pushed to
/// every one that is connected.
struct TransferProgressRow: View {
    var title: String
    var systemImage: String
    var progress: PutBytesTransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            if progress.totalBytes > 0 {
                ProgressView(
                    value: Double(progress.bytesSent),
                    total: Double(progress.totalBytes)
                )
                Text("\(progress.bytesSent, format: .number) of \(progress.totalBytes, format: .number) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .accessibilityLabel(Text("Preparing installation"))
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

struct ApplicationSection<Detail: View>: View {
    var title: LocalizedStringKey
    var applications: [WatchApplication]
    var activeWatchfaceID: UUID?
    var installedApplicationIDs: Set<UUID>?
    var isOperationInProgress: Bool
    /// Whether the rows on screen are a sifted subset, whose offsets say
    /// nothing about the launcher order underneath.
    var isFiltering: Bool = false
    var storeImageURL: (WatchApplication) async -> URL? = { _ in nil }
    var requestRemoval: (WatchApplication) -> Void
    var configureApplication: (WatchApplication) -> Void
    var editGlance: (WatchApplication) -> Void
    var activateWatchface: (WatchApplication) -> Void
    var moveApplications: (IndexSet, Int) -> Void
    @ViewBuilder var detail: (WatchApplication) -> Detail

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationListRow(
                    application: application,
                    isActive: activeWatchfaceID == application.id,
                    isInstalled: installedApplicationIDs.map { $0.contains(application.id) },
                    isOperationInProgress: isOperationInProgress,
                    storeImageURL: { await storeImageURL(application) },
                    requestRemoval: { requestRemoval(application) },
                    configureApplication: { configureApplication(application) },
                    editGlance: { editGlance(application) },
                    activateWatchface: { activateWatchface(application) },
                    detail: { detail(application) }
                )
                // The id the List's selection is keyed by, so ticking a row in
                // edit mode collects it for a delete that takes several at once.
                .tag(application.id)
            }
            .onMove(perform: moveApplications)
            .moveDisabled(isOperationInProgress || isFiltering)
        }
    }
}

struct ApplicationListRow<Detail: View>: View {
    var application: WatchApplication
    var isActive: Bool
    var isInstalled: Bool?
    var isOperationInProgress: Bool
    var storeImageURL: () async -> URL? = { nil }
    var requestRemoval: () -> Void
    var configureApplication: () -> Void
    var editGlance: () -> Void
    var activateWatchface: () -> Void
    @ViewBuilder var detail: () -> Detail

    @State private var imageURL: URL?

    var body: some View {
        NavigationLink {
            detail()
        } label: {
            ApplicationRow(
                name: application.displayName,
                companyName: application.companyName,
                versionLabel: application.versionLabel,
                kind: application.kind,
                isActive: isActive,
                isInstalled: isInstalled,
                imageURL: imageURL
            )
        }
        // Asked when the row first appears: the model remembers both answers
        // and refusals, so a long list settles into cached lookups.
        .task { imageURL = await storeImageURL() }
        // Red, but not `role: .destructive`: that role takes the row out of the
        // list by itself, and the library still had the application until the
        // alert was answered — a row deleted from under a count that had not
        // changed is exactly what UIKit threw over.
        .swipeActions {
            Button("Remove", action: requestRemoval)
                .tint(.red)
                .disabled(isOperationInProgress)
        }
        .contextMenu {
            if application.isConfigurable {
                Button("Configure", systemImage: "gearshape", action: configureApplication)
            }
            if application.kind == .watchapp {
                Button("Launcher Line", systemImage: "text.line.first.and.arrowtriangle.forward", action: editGlance)
            }
            if application.kind == .watchface {
                Button(isActive ? "Active" : "Activate", systemImage: "play.circle", action: activateWatchface)
                    .disabled(isActive)
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive, action: requestRemoval)
                .disabled(isOperationInProgress)
        }
    }
}

/// A row that leads to the application rather than acting on it: what used to
/// be buttons crowded in beside the name is on the screen the row opens, where
/// each has room to say what it does.
struct ApplicationRow: View {
    var name: String
    var companyName: String
    var versionLabel: String
    var kind: WatchApplicationKind
    var isActive: Bool
    /// Nil when no watch is connected.
    var isInstalled: Bool?
    /// The store's picture of this application — a watchface's first
    /// screenshot, an app's icon — where the store has one. A package carries
    /// no images of its own, so a side-loaded application the store never
    /// listed keeps the symbol.
    var imageURL: URL? = nil

    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: imageURL) { image in
                image.resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } placeholder: {
                Image(systemName: kind == .watchface ? "clock" : "square.grid.2x2")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }
            .frame(width: 44, height: 50)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                if !companyName.isEmpty {
                    Text(companyName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let isInstalled {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed on this watch", systemImage: "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            // Said rather than offered: tapping the row opens the screen that
            // can change it.
            if kind == .watchface, isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("Active"))
            }
            Text(versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

struct ApplicationPlaceholderRow: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
            VStack(alignment: .leading, spacing: 4) {
                Text("Application Name")
                    .font(.headline)
                Text("Developer")
                    .font(.subheadline)
            }
        }
        .frame(minHeight: 44)
    }
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
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}
