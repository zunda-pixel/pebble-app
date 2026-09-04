import SwiftUI
import PebbleProtocol

struct ApplicationsView: View {
    var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var isChoosingPackage = false
    @State private var isShowingCatalog = false
    @State private var selectedWatchID: String?
    @State private var glanceApplication: PebbleApplication?

    // The picked watch while it stays connected, otherwise the primary one.
    private var displayedWatchID: String? {
        if let selectedWatchID,
           model.connectedDevices.contains(where: { $0.id == selectedWatchID }) {
            return selectedWatchID
        }
        return model.connectedDevice?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.connectedDevices.count > 1 {
                Picker("Watch", selection: Binding(
                    get: { displayedWatchID ?? "" },
                    set: { selectedWatchID = $0 }
                )) {
                    ForEach(model.connectedDevices) { device in
                        Text(device.name).tag(device.id)
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
            watchApplications: model.watchApplications,
            watchfaces: model.watchfaces,
            activeWatchfaceID: model.activeWatchfaceID,
            favoriteWatchfaceIDs: model.favoriteWatchfaceIDs,
            installedApplicationIDs: displayedWatchID.map { model.installedApplicationIDs(on: $0) },
            isLoading: model.isLoadingApplications,
            errorMessage: model.applicationLibraryErrorMessage,
            operationStatusMessage: model.applicationManagementStatusMessage,
            isOperationInProgress: model.isApplicationManagementBusy,
            installingApplicationName: transfer?.name,
            installationProgress: transfer?.progress,
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
            toggleFavoriteWatchface: { application in
                model.toggleFavoriteWatchface(application)
                undoManager?.registerUndo(withTarget: model) { target in
                    target.toggleFavoriteWatchface(application)
                }
                undoManager?.setActionName("Favorite Watchface")
            }
        )
        .navigationTitle(Text("Apps"))
        .task { await model.loadApplications() }
        .toolbar {
            ToolbarItem {
                Button("Add App", systemImage: "plus") {
                    isShowingCatalog = true
                }
            }
        }
        .sheet(isPresented: $isShowingCatalog) {
            CatalogView(
                model: model,
                isImportingApplication: model.isImportingApplication,
                isImportDisabled: model.isApplicationManagementBusy,
                importApplication: { isChoosingPackage = true }
            )
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
        .sheet(isPresented: Binding(
            get: { model.configurationURL != nil },
            set: { presented in
                if !presented { Task { await model.closeConfiguration() } }
            }
        )) {
            NavigationStack {
                Group {
                    if let configurationURL = model.configurationURL {
                        ConfigurationWebView(url: configurationURL) { response in
                            Task { await model.closeConfiguration(response: response) }
                        }
                    }
                }
                .navigationTitle(model.configurationApplication?.displayName ?? "App Settings")
                .toolbar {
                    // Closing, not confirming: the page has its own submit, and
                    // whatever it posted has already been applied by the time
                    // this is reachable.
                    Button(role: .close) { Task { await model.closeConfiguration() } }
                }
            }
        }
    }
}

struct ApplicationsContent: View {
    var watchApplications: [PebbleApplication]
    var watchfaces: [PebbleApplication]
    var activeWatchfaceID: UUID?
    var favoriteWatchfaceIDs: Set<UUID>
    /// Nil when no watch is connected: install state is unknown, not shown.
    var installedApplicationIDs: Set<UUID>?
    var isLoading: Bool
    var errorMessage: LocalizedStringKey?
    var operationStatusMessage: LocalizedStringKey?
    var isOperationInProgress: Bool
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var removeApplication: (UUID) -> Void
    var reorderApplications: (PebbleApplicationKind, IndexSet, Int) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var editGlance: (PebbleApplication) -> Void
    var activateWatchface: (PebbleApplication) -> Void
    var toggleFavoriteWatchface: (PebbleApplication) -> Void

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
                    statusMessage: operationStatusMessage,
                    installingApplicationName: installingApplicationName,
                    installationProgress: installationProgress,
                    errorMessage: errorMessage
                )
                List {
                    if !watchApplications.isEmpty {
                        ApplicationSection(
                            title: "Watch Apps",
                            applications: watchApplications,
                            activeWatchfaceID: activeWatchfaceID,
                            favoriteWatchfaceIDs: favoriteWatchfaceIDs,
                            installedApplicationIDs: installedApplicationIDs,
                            isOperationInProgress: isOperationInProgress,
                            removeApplication: removeApplication,
                            configureApplication: configureApplication,
                            editGlance: editGlance,
                            activateWatchface: activateWatchface,
                            toggleFavoriteWatchface: toggleFavoriteWatchface,
                            moveApplications: { offsets, destination in
                                reorderApplications(.watchapp, offsets, destination)
                            }
                        )
                    }
                    if !watchfaces.isEmpty {
                        ApplicationSection(
                            title: "Watchfaces",
                            applications: watchfaces,
                            activeWatchfaceID: activeWatchfaceID,
                            favoriteWatchfaceIDs: favoriteWatchfaceIDs,
                            installedApplicationIDs: installedApplicationIDs,
                            isOperationInProgress: isOperationInProgress,
                            removeApplication: removeApplication,
                            configureApplication: configureApplication,
                            editGlance: editGlance,
                            activateWatchface: activateWatchface,
                            toggleFavoriteWatchface: toggleFavoriteWatchface,
                            moveApplications: { offsets, destination in
                                reorderApplications(.watchface, offsets, destination)
                            }
                        )
                    }
                }
            }
        }
    }
}

/// What the library is in the middle of, and what went wrong doing it.
struct ApplicationOperationBanner: View {
    var statusMessage: LocalizedStringKey?
    var installingApplicationName: String?
    var installationProgress: PutBytesTransferProgress?
    var errorMessage: LocalizedStringKey?

    private var isEmpty: Bool {
        statusMessage == nil && errorMessage == nil
            && (installingApplicationName == nil || installationProgress == nil)
    }

    var body: some View {
        if !isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let statusMessage {
                    Label(statusMessage, systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                if let installingApplicationName, let installationProgress {
                    InstallationProgressRow(
                        applicationName: installingApplicationName,
                        progress: installationProgress
                    )
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

struct InstallationProgressRow: View {
    var applicationName: String
    var progress: PutBytesTransferProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(applicationName, systemImage: "arrow.down.app")
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

struct ApplicationSection: View {
    var title: LocalizedStringKey
    var applications: [PebbleApplication]
    var activeWatchfaceID: UUID?
    var favoriteWatchfaceIDs: Set<UUID>
    var installedApplicationIDs: Set<UUID>?
    var isOperationInProgress: Bool
    var removeApplication: (UUID) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var editGlance: (PebbleApplication) -> Void
    var activateWatchface: (PebbleApplication) -> Void
    var toggleFavoriteWatchface: (PebbleApplication) -> Void
    var moveApplications: (IndexSet, Int) -> Void

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationListRow(
                    application: application,
                    isActive: activeWatchfaceID == application.id,
                    isFavorite: favoriteWatchfaceIDs.contains(application.id),
                    isInstalled: installedApplicationIDs.map { $0.contains(application.id) },
                    isOperationInProgress: isOperationInProgress,
                    removeApplication: { removeApplication(application.id) },
                    configureApplication: { configureApplication(application) },
                    editGlance: { editGlance(application) },
                    activateWatchface: { activateWatchface(application) },
                    toggleFavoriteWatchface: { toggleFavoriteWatchface(application) }
                )
            }
            .onMove(perform: moveApplications)
            .moveDisabled(isOperationInProgress)
        }
    }
}

struct ApplicationListRow: View {
    var application: PebbleApplication
    var isActive: Bool
    var isFavorite: Bool
    var isInstalled: Bool?
    var isOperationInProgress: Bool
    var removeApplication: () -> Void
    var configureApplication: () -> Void
    var editGlance: () -> Void
    var activateWatchface: () -> Void
    var toggleFavoriteWatchface: () -> Void

    @State private var isConfirmingRemoval = false

    var body: some View {
        ApplicationRow(
            name: application.displayName,
            companyName: application.companyName,
            versionLabel: application.versionLabel,
            kind: application.kind,
            isActive: isActive,
            isFavorite: isFavorite,
            isInstalled: isInstalled,
            isConfigurable: application.isConfigurable,
            configure: configureApplication,
            activate: activateWatchface,
            toggleFavorite: toggleFavoriteWatchface
        )
        .swipeActions {
            Button("Remove", role: .destructive) {
                isConfirmingRemoval = true
            }
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
                Button(
                    isFavorite ? "Remove Favorite" : "Favorite",
                    systemImage: "star",
                    action: toggleFavoriteWatchface
                )
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) {
                isConfirmingRemoval = true
            }
            .disabled(isOperationInProgress)
        }
        .confirmationDialog(
            Text("Remove \(application.displayName)?"),
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Application", role: .destructive, action: removeApplication)
            Button(role: .cancel) {}
        } message: {
            Text("The application and its settings will be removed. A Pebble that is not connected is told the next time it is.")
        }
    }
}

struct ApplicationRow: View {
    var name: String
    var companyName: String
    var versionLabel: String
    var kind: PebbleApplicationKind
    var isActive: Bool
    var isFavorite: Bool
    /// Nil when no watch is connected.
    var isInstalled: Bool?
    var isConfigurable: Bool
    var configure: () -> Void
    var activate: () -> Void
    var toggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: kind == .watchface ? "clock" : "square.grid.2x2")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
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
            if kind == .watchface {
                Button(isFavorite ? "Remove Favorite" : "Favorite", systemImage: isFavorite ? "star.fill" : "star", action: toggleFavorite)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                Button(isActive ? "Active" : "Activate", systemImage: isActive ? "checkmark.circle.fill" : "play.circle", action: activate)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isActive)
                    .accessibilityHint(Text("Makes this the active watchface"))
            }
            Text(versionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if isConfigurable {
                Button("Configure", systemImage: "gearshape", action: configure)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityHint(Text("Opens this watch application's settings"))
            }
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
            favoriteWatchfaceIDs: Set(PreviewSamples.watchfaces.map(\.id)),
            installedApplicationIDs: Set(PreviewSamples.watchApplications.prefix(1).map(\.id)),
            isLoading: false,
            errorMessage: nil,
            operationStatusMessage: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            toggleFavoriteWatchface: { _ in }
        )
    }
}

#Preview("Installing") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: PreviewSamples.watchApplications,
            watchfaces: [],
            activeWatchfaceID: nil,
            favoriteWatchfaceIDs: [],
            installedApplicationIDs: nil,
            isLoading: false,
            errorMessage: nil,
            operationStatusMessage: "Sending Timeline Weather to Pebble 5209.",
            isOperationInProgress: true,
            installingApplicationName: "Timeline Weather",
            installationProgress: PreviewSamples.transferProgress,
            removeApplication: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            toggleFavoriteWatchface: { _ in }
        )
    }
}

#Preview("Empty") {
    NavigationStack {
        ApplicationsContent(
            watchApplications: [],
            watchfaces: [],
            activeWatchfaceID: nil,
            favoriteWatchfaceIDs: [],
            installedApplicationIDs: nil,
            isLoading: false,
            errorMessage: nil,
            operationStatusMessage: nil,
            isOperationInProgress: false,
            installingApplicationName: nil,
            installationProgress: nil,
            removeApplication: { _ in },
            reorderApplications: { _, _, _ in },
            configureApplication: { _ in },
            editGlance: { _ in },
            activateWatchface: { _ in },
            toggleFavoriteWatchface: { _ in }
        )
    }
}
