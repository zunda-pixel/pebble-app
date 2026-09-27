import SwiftUI
import PebbleProtocol

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

#Preview("Watch app") {
    NavigationStack {
        List {
            ApplicationListRow(
                application: PreviewSamples.watchApplications[0],
                isActive: false,
                isInstalled: true,
                isOperationInProgress: false,
                requestRemoval: {},
                configureApplication: {},
                editGlance: {},
                activateWatchface: {},
                detail: { Text(verbatim: PreviewSamples.watchApplications[0].displayName) }
            )
        }
    }
}
