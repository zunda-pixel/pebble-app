import SwiftUI
import PebbleProtocol

/// One application, as the row that leads here could not show it: the whole of
/// what the package said about itself, and every action that was otherwise only
/// in a context menu nobody opens.
struct ApplicationDetailContent: View {
    var application: PebbleApplication
    var isActive: Bool
    /// Nil when no watch is connected: install state is unknown, not shown.
    var isInstalled: Bool?
    var isOperationInProgress: Bool
    var configureApplication: () -> Void
    var editGlance: () -> Void
    var activateWatchface: () -> Void
    var removeApplication: () -> Void

    @State private var isConfirmingRemoval = false

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                LabeledContent("Kind") {
                    kindTitle
                }
                LabeledContent("Version", value: application.versionLabel)
                if !application.companyName.isEmpty {
                    LabeledContent("Developer", value: application.companyName)
                }
                if !application.targetPlatforms.isEmpty {
                    LabeledContent("Built For") {
                        Text(verbatim: application.targetPlatforms.joined(separator: ", "))
                    }
                }
                if application.hasCompanionJavaScript {
                    Label("Has companion JavaScript", systemImage: "curlybraces")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            } footer: {
                if let isInstalled, !isInstalled {
                    Text("The watch is told about this application the next time it connects.")
                }
            }

            if application.kind == .watchface {
                Section("Watchface") {
                    Button(isActive ? "Active" : "Activate", systemImage: "play.circle", action: activateWatchface)
                        .disabled(isActive || isOperationInProgress)
                }
            }

            if application.isConfigurable || application.kind == .watchapp {
                Section("Settings") {
                    if application.isConfigurable {
                        Button("Configure", systemImage: "gearshape", action: configureApplication)
                            .disabled(isOperationInProgress)
                    }
                    if application.kind == .watchapp {
                        Button(
                            "Launcher Line",
                            systemImage: "text.line.first.and.arrowtriangle.forward",
                            action: editGlance
                        )
                    }
                }
            }

            Section {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(isOperationInProgress)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: application.displayName))
        // An alert rather than a confirmation dialog: this one has a row to
        // anchor to, but the two questions should read the same wherever the
        // removal was asked for.
        .alert(
            Text("Remove \(application.displayName)?"),
            isPresented: $isConfirmingRemoval
        ) {
            Button("Remove Application", role: .destructive, action: removeApplication)
            Button(role: .cancel) {}
        } message: {
            Text("The application and its settings will be removed. A Pebble that is not connected is told the next time it is.")
        }
    }

    // Hoisted: a conditional cannot stand where a view argument is expected,
    // and the two names have to stay keys to be translated.
    private var kindTitle: Text {
        application.kind == .watchface ? Text("Watchface") : Text("Watch App")
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: application.kind == .watchface ? "clock" : "square.grid.2x2")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: application.displayName)
                    .font(.title2.bold())
                if let isInstalled {
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
}

struct ApplicationDetailView: View {
    var model: AppModel
    var application: PebbleApplication
    var watchID: WatchID?
    var editGlance: (PebbleApplication) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Read from the library rather than held: a removal elsewhere, or a
    /// reinstall, should show here without going back first.
    private var current: PebbleApplication? {
        (model.watchApplications + model.watchfaces).first { $0.id == application.id }
    }

    var body: some View {
        Group {
            if let current {
                ApplicationDetailContent(
                    application: current,
                    isActive: model.activeWatchfaceID == current.id,
                    isInstalled: watchID.map { model.installedApplicationIDs(on: $0).contains(current.id) },
                    isOperationInProgress: model.isApplicationManagementBusy,
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
    }
}

#Preview("Watch App") {
    NavigationStack {
        ApplicationDetailContent(
            application: PreviewSamples.watchApplications[0],
            isActive: false,
            isInstalled: true,
            isOperationInProgress: false,
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("Watchface, not installed") {
    NavigationStack {
        ApplicationDetailContent(
            application: PreviewSamples.watchfaces[0],
            isActive: true,
            isInstalled: false,
            isOperationInProgress: false,
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}

#Preview("No watch connected") {
    NavigationStack {
        ApplicationDetailContent(
            application: PreviewSamples.watchApplications[1],
            isActive: false,
            isInstalled: nil,
            isOperationInProgress: false,
            configureApplication: {},
            editGlance: {},
            activateWatchface: {},
            removeApplication: {}
        )
    }
}
