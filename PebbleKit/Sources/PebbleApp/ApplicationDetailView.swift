import SwiftUI
import PebbleProtocol

/// One application, however it was reached.
///
/// The two screens this replaces had a type each: the library's
/// `WatchApplication`, read out of the package the watch is sent, and the
/// store's `CatalogApplication`, read off the feed. An application can be in
/// both, in the library alone, or in the store alone, so neither type could be
/// the subject on its own.
///
/// Where both know a fact the package wins, because it describes the copy the
/// reader actually has and the store's row may be a version ahead. The store
/// fills in only what a package cannot say about itself: what it is for, what
/// it looks like, and where its page is.
struct ApplicationDetailSubject: Equatable, Sendable {
    var id: UUID
    var name: String
    var developer: String
    var version: String
    var kind: WatchApplicationKind
    var platforms: [String]
    /// The library's copy. Absent for something only in the store.
    var installed: WatchApplication?
    /// The store's copy. Absent for a package the store never listed, and
    /// absent until the lookup answers.
    var store: CatalogApplication?

    init(installed: WatchApplication, store: CatalogApplication?) {
        self.id = installed.id
        self.name = installed.displayName
        // The package may leave these out; the store's row then says it
        // instead, which beats an empty row.
        self.developer = installed.companyName.isEmpty ? store?.developer ?? "" : installed.companyName
        self.version = installed.versionLabel
        self.kind = installed.kind
        self.platforms = installed.targetPlatforms.isEmpty
            ? store?.supportedPlatforms ?? []
            : installed.targetPlatforms
        self.installed = installed
        self.store = store
    }

    init(store: CatalogApplication, installed: WatchApplication?) {
        // Installed wins wherever it is there, so the two ways in agree.
        if let installed {
            self = Self(installed: installed, store: store)
        } else {
            self.id = store.id
            self.name = store.name
            self.developer = store.developer
            self.version = store.version
            self.kind = store.kind
            self.platforms = store.supportedPlatforms
            self.installed = nil
            self.store = store
        }
    }
}

/// One application, as the row that leads here could not show it: the whole of
/// what the package said about itself, what the store says about it, and every
/// action that was otherwise only in a context menu nobody opens.
struct ApplicationDetailContent: View {
    var subject: ApplicationDetailSubject
    var isActive: Bool
    /// Nil when no watch is connected: install state is unknown, not shown.
    var isInstalled: Bool?
    /// Nil while the store has not answered, or has no such application.
    var installationState: CatalogInstallationState?
    var isInstalling: Bool
    var isAnyInstallRunning: Bool
    var isOperationInProgress: Bool
    var feedback: FeatureFeedback?
    /// Which watches this application is on its way to, one per watch.
    ///
    /// Empty most of the time, and empty for the whole of the download that
    /// precedes a store install — during which `isInstalling` is what says
    /// anything is happening at all.
    var transfers: [WatchApplicationTransfer] = []
    var install: () -> Void
    var configureApplication: () -> Void
    /// Nil where the launcher line cannot be edited from here, which leaves
    /// the row out rather than showing one that does nothing.
    var editGlance: (() -> Void)?
    var activateWatchface: () -> Void
    var removeApplication: () -> Void

    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                header
            }
            
            Section {
                if canInstall {
                    Button(installButtonTitle, systemImage: "arrow.down.app", action: install)
                        .disabled(isAnyInstallRunning)
                }
                // Only while there is nothing better to show. A spinner beside
                // a bar that knows the byte count says less than the bar, and
                // the two phases do not overlap: the download comes first,
                // then a watch is written to.
                if isInstalling && transfers.isEmpty { ProgressView() }
                // The bytes used to be shown on the library screen alone,
                // which is behind this one and has its tab bar hidden — so
                // installing from here left the reader an indeterminate
                // spinner while the numbers went somewhere they could not
                // look. One row per watch, because the transfers get on at
                // their own speeds.
                ForEach(transfers) { transfer in
                    TransferProgressRow(
                        title: transfer.watchName,
                        systemImage: "applewatch.radiowaves.left.and.right",
                        progress: transfer.progress
                    )
                }
                FeedbackBanner(feedback: feedback)
            }
            
            if let releaseNotes = subject.store?.releaseNotes, !releaseNotes.isEmpty {
                Section("Release Notes") { Text(releaseNotes) }
            }

            if subject.installed != nil, subject.kind == .watchface {
                Section("Watchface") {
                    Button(isActive ? "Active" : "Activate", systemImage: "play.circle", action: activateWatchface)
                        .disabled(isActive || isOperationInProgress)
                }
            }
            
            if let screenshots = subject.store?.screenshotURLs, !screenshots.isEmpty {
                Section("Screenshots") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(screenshots, id: \.self) { url in
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(width: 220, height: 220)
                                .accessibilityLabel(Text("Screenshot of \(subject.name)"))
                            }
                        }
                    }
                }
            }
            
            if let summary = subject.store?.summary, !summary.isEmpty {
                Section {
                    Text(summary)
                }
            }

            Section {
                LabeledContent("Kind") {
                    kindTitle
                }
                LabeledContent("Version", value: subject.version)
                if !subject.developer.isEmpty {
                    LabeledContent("Developer", value: subject.developer)
                }
                if let category = subject.store?.category, !category.isEmpty {
                    LabeledContent("Category", value: category)
                }
                if !subject.platforms.isEmpty {
                    LabeledContent("Built For") {
                        Text(verbatim: subject.platforms.sorted().joined(separator: ", "))
                    }
                }
                if subject.installed?.hasCompanionJavaScript == true {
                    Label("Has companion JavaScript", systemImage: "curlybraces")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            } footer: {
                if let isInstalled, !isInstalled, subject.installed != nil {
                    Text("The watch is told about this application the next time it connects.")
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            // A bar at the bottom on the phone, where the thumb is, and the
            // window's own toolbar on the Mac. `bottomBar` is a placement iOS
            // has and a window does not.
            #if os(iOS)
            ToolbarItemGroup(placement: .bottomBar) { actions }
            #else
            ToolbarItemGroup(placement: .primaryAction) { actions }
            #endif
        }
        #if os(iOS)
        // The bottom bar and the tab bar want the same edge, and the actions
        // belong to what is on screen rather than to moving between tabs.
        .toolbarVisibility(.hidden, for: .tabBar)
        #endif
        .navigationTitle(Text(verbatim: subject.name))
        // An alert rather than a confirmation dialog: this one has a row to
        // anchor to, but the two questions should read the same wherever the
        // removal was asked for.
        .alert(
            Text("Remove \(subject.name)?"),
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove Application", role: .destructive, action: removeApplication)
            Button(role: .cancel) {}
        } message: {
            Text("The application and its settings will be removed. A Pebble that is not connected is told the next time it is.")
        }
    }

    /// Everything that can be done to this application, in one place so that
    /// the two bars it goes into cannot drift apart.
    ///
    /// Each is absent rather than disabled where it does not apply: there is
    /// nothing to configure in an application that is not installed, and no
    /// store page for a package the store never listed.
    @ViewBuilder private var actions: some View {
        if let installed = subject.installed, installed.isConfigurable {
            Button("Configure", systemImage: "gearshape", action: configureApplication)
                .disabled(isOperationInProgress)
        }
        if subject.installed?.kind == .watchapp, let editGlance {
            Button(
                "Launcher Line",
                systemImage: "text.line.first.and.arrowtriangle.forward",
                action: editGlance
            )
        }
        // The feed carries a summary and a few screenshots; the store page has
        // the rest — every screenshot, the whole changelog, and the hearts.
        if let storePageURL = subject.store?.storePageURL {
            Link(destination: storePageURL) {
                Label("View in Store", systemImage: "safari")
            }
        }
        if subject.installed != nil {
            #if os(iOS)
            // Pushed to the far end of the bar, since it is the one that
            // cannot be undone. In a form it would only be an empty row.
            Spacer()
            #endif
            Button("Remove", systemImage: "trash", role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(isOperationInProgress)
        }
    }

    /// Only where the store has something to install, and something to gain by
    /// it. `nil` is a store that has not answered, which is not an offer.
    private var canInstall: Bool {
        installationState == .available || installationState == .updateAvailable
    }

    // Hoisted: a conditional cannot stand where a view argument is expected,
    // and the two names have to stay keys to be translated.
    private var kindTitle: Text {
        subject.kind == .watchface ? Text("Watchface") : Text("Watch App")
    }

    private var installButtonTitle: LocalizedStringKey {
        installationState == .updateAvailable ? "Update" : "Install"
    }

    private var header: some View {
        HStack(spacing: 16) {
            icon
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: subject.name)
                    .font(.title2.bold())
                if subject.installed == nil {
                    CatalogStateLabel(state: installationState ?? .available)
                        .font(.subheadline)
                } else if let isInstalled {
                    if isInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    } else {
                        Label("Not installed on this watch", systemImage: "circle.dashed")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        // The store has a real icon; a package installed from a file has only
        // what its kind suggests.
        if let iconURL = subject.store?.iconURL {
            AsyncImage(url: iconURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                kindSymbol
            }
        } else {
            kindSymbol
        }
    }

    private var kindSymbol: some View {
        Image(systemName: subject.kind == .watchface ? "clock" : "square.grid.2x2")
            .font(.system(size: 40))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
    }
}

/// The detail screen reached from the library.
struct ApplicationDetailView: View {
    var model: AppModel
    var application: WatchApplication
    var watchID: WatchID?
    var editGlance: (WatchApplication) -> Void
    @Environment(\.dismiss) private var dismiss

    /// What the store says, asked for once the screen is up. Nil is both "not
    /// asked yet" and "the store does not have it": neither shows anything, so
    /// the screen does not have to tell them apart.
    @State private var storeEntry: CatalogApplication?

    /// Read from the library rather than held: a removal elsewhere, or a
    /// reinstall, should show here without going back first.
    private var current: WatchApplication? {
        (model.applications.apps + model.applications.watchfaces).first { $0.id == application.id }
    }

    var body: some View {
        Group {
            if let current {
                ApplicationDetailContent(
                    subject: ApplicationDetailSubject(installed: current, store: storeEntry),
                    isActive: model.applications.activeWatchfaceID == current.id,
                    isInstalled: watchID.map { model.installedApplicationIDs(on: $0).contains(current.id) },
                    installationState: storeEntry.map { model.catalogInstallationState(for: $0) },
                    isInstalling: model.catalog.installingApplicationID == current.id,
                    isAnyInstallRunning: model.catalog.installingApplicationID != nil,
                    isOperationInProgress: model.isApplicationManagementBusy,
                    // Only this application's own install, so that a catalogue
                    // banner about something else does not surface here.
                    feedback: model.catalog.installingApplicationID == current.id
                        ? model.catalog.feedback
                        : nil,
                    // Asked about this application, so a library synchronization
                    // that pushes it to a watch that just connected shows here
                    // too — `installingApplicationID` only knows about installs
                    // started from the store.
                    transfers: model.transfers(of: current.id),
                    install: {
                        if let storeEntry {
                            Task { await model.installCatalogApplication(storeEntry) }
                        }
                    },
                    configureApplication: { Task { await model.configureApplication(current) } },
                    editGlance: { editGlance(current) },
                    activateWatchface: { Task { await model.activateWatchface(current) } },
                    removeApplication: {
                        Task {
                            await model.removeApplication(id: current.id)
                            dismiss()
                        }
                    }
                )
            } else {
                // Removed while this was open, from here or from the list.
                ContentUnavailableView(
                    "Removed",
                    systemImage: "trash",
                    description: Text("This application is no longer in the library.")
                )
            }
        }
        .task(id: application.id) {
            storeEntry = await model.storeEntry(for: application.id)
        }
    }
}

/// The same screen, reached from the catalogue.
///
/// The store's copy is in hand here and the library is what has to be looked
/// up, which is the other way round from `ApplicationDetailView` — and needs
/// no network, because the library is already loaded.
struct CatalogApplicationDetailView: View {
    var application: CatalogApplication
    var model: AppModel
    var editGlance: (WatchApplication) -> Void
    @Environment(\.dismiss) private var dismiss

    private var installed: WatchApplication? {
        (model.applications.apps + model.applications.watchfaces).first { $0.id == application.id }
    }

    var body: some View {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(store: application, installed: installed),
            isActive: model.applications.activeWatchfaceID == application.id,
            isInstalled: nil,
            installationState: model.catalogInstallationState(for: application),
            isInstalling: model.catalog.installingApplicationID == application.id,
            isAnyInstallRunning: model.catalog.installingApplicationID != nil,
            isOperationInProgress: model.isApplicationManagementBusy,
            feedback: model.catalog.feedback,
            transfers: model.transfers(of: application.id),
            install: { Task { await model.installCatalogApplication(application) } },
            configureApplication: {
                if let installed { Task { await model.configureApplication(installed) } }
            },
            editGlance: installed.map { installed in { editGlance(installed) } },
            activateWatchface: {
                if let installed { Task { await model.activateWatchface(installed) } }
            },
            removeApplication: {
                if let installed {
                    Task {
                        await model.removeApplication(id: installed.id)
                        dismiss()
                    }
                }
            }
        )
    }
}

#Preview("Installed watch app") {
    NavigationStack {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(
                installed: PreviewSamples.watchApplications[0],
                store: PreviewSamples.catalogApplication
            ),
            isActive: false,
            isInstalled: true,
            installationState: .installed,
            isInstalling: false,
            isAnyInstallRunning: false,
            isOperationInProgress: false,
            feedback: nil,
            install: {},
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("On its way to two watches") {
    NavigationStack {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(store: PreviewSamples.catalogApplication, installed: nil),
            isActive: false,
            isInstalled: nil,
            installationState: .available,
            isInstalling: true,
            isAnyInstallRunning: true,
            isOperationInProgress: true,
            feedback: .progress("Installing Orbit…"),
            // One row per watch. They are sent the same application and get on
            // at their own speeds, which is the thing a single bar could not say.
            transfers: [
                WatchApplicationTransfer(
                    watchID: WatchID("preview-watch"),
                    watchName: "Pebble 5209",
                    progress: PutBytesTransferProgress(bytesSent: 240_000, totalBytes: 512_000)
                ),
                WatchApplicationTransfer(
                    watchID: WatchID("preview-time"),
                    watchName: "Pebble Time",
                    progress: PutBytesTransferProgress(bytesSent: 32_768, totalBytes: 512_000)
                ),
            ],
            install: {},
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("Fetching the package, no watch written to yet") {
    NavigationStack {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(store: PreviewSamples.catalogApplication, installed: nil),
            isActive: false,
            isInstalled: nil,
            installationState: .available,
            isInstalling: true,
            isAnyInstallRunning: true,
            isOperationInProgress: false,
            // Interpolated rather than spelled out, so this is the key the
            // model already writes — `Downloading %@…` — and not a second one
            // that would need translating for a preview alone.
            feedback: .progress("Downloading \("Orbit")…"),
            // Empty: the download comes before any watch is written to, so the
            // indeterminate spinner is all there is to show.
            transfers: [],
            install: {},
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("In the store only") {
    NavigationStack {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(store: PreviewSamples.catalogApplication, installed: nil),
            isActive: false,
            isInstalled: nil,
            installationState: .available,
            isInstalling: false,
            isAnyInstallRunning: false,
            isOperationInProgress: false,
            feedback: nil,
            install: {},
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("Installed, the store does not have it") {
    NavigationStack {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(installed: PreviewSamples.watchfaces[0], store: nil),
            isActive: true,
            isInstalled: false,
            installationState: nil,
            isInstalling: false,
            isAnyInstallRunning: false,
            isOperationInProgress: false,
            feedback: nil,
            install: {},
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}
