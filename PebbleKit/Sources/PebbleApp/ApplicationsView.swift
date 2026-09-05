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

struct ApplicationsContent<Detail: View>: View {
    var watchApplications: [PebbleApplication]
    var watchfaces: [PebbleApplication]
    var activeWatchfaceID: UUID?
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
    @ViewBuilder var detail: (PebbleApplication) -> Detail

    @State private var applicationToRemove: PebbleApplication?

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
            }
        }
    }

    private var groups: [ApplicationGroup] {
        [
            ApplicationGroup(kind: .watchapp, title: "Watch Apps", applications: watchApplications),
            ApplicationGroup(kind: .watchface, title: "Watchfaces", applications: watchfaces),
        ]
        .filter { !$0.applications.isEmpty }
    }
}

/// One of the list's sections, as something the list can tell apart from the
/// other by what it holds rather than by where it sits.
private struct ApplicationGroup: Identifiable {
    var kind: PebbleApplicationKind
    var title: LocalizedStringKey
    var applications: [PebbleApplication]

    var id: PebbleApplicationKind { kind }
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

struct ApplicationSection<Detail: View>: View {
    var title: LocalizedStringKey
    var applications: [PebbleApplication]
    var activeWatchfaceID: UUID?
    var installedApplicationIDs: Set<UUID>?
    var isOperationInProgress: Bool
    var requestRemoval: (PebbleApplication) -> Void
    var configureApplication: (PebbleApplication) -> Void
    var editGlance: (PebbleApplication) -> Void
    var activateWatchface: (PebbleApplication) -> Void
    var moveApplications: (IndexSet, Int) -> Void
    @ViewBuilder var detail: (PebbleApplication) -> Detail

    var body: some View {
        Section(title) {
            ForEach(applications) { application in
                ApplicationListRow(
                    application: application,
                    isActive: activeWatchfaceID == application.id,
                    isInstalled: installedApplicationIDs.map { $0.contains(application.id) },
                    isOperationInProgress: isOperationInProgress,
                    requestRemoval: { requestRemoval(application) },
                    configureApplication: { configureApplication(application) },
                    editGlance: { editGlance(application) },
                    activateWatchface: { activateWatchface(application) },
                    detail: { detail(application) }
                )
            }
            .onMove(perform: moveApplications)
            .moveDisabled(isOperationInProgress)
        }
    }
}

struct ApplicationListRow<Detail: View>: View {
    var application: PebbleApplication
    var isActive: Bool
    var isInstalled: Bool?
    var isOperationInProgress: Bool
    var requestRemoval: () -> Void
    var configureApplication: () -> Void
    var editGlance: () -> Void
    var activateWatchface: () -> Void
    @ViewBuilder var detail: () -> Detail

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
                isInstalled: isInstalled
            )
        }
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
    var kind: PebbleApplicationKind
    var isActive: Bool
    /// Nil when no watch is connected.
    var isInstalled: Bool?

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
            detail: { application in Text(verbatim: application.displayName) }
        )
    }
}
