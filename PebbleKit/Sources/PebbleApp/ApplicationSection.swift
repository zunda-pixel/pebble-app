import SwiftUI
import PebbleProtocol

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

#Preview("Watch apps") {
    NavigationStack {
        List {
            ApplicationSection(
                title: "Watch Apps",
                applications: PreviewSamples.watchApplications,
                activeWatchfaceID: nil,
                installedApplicationIDs: Set(PreviewSamples.watchApplications.prefix(1).map(\.id)),
                isOperationInProgress: false,
                requestRemoval: { _ in },
                configureApplication: { _ in },
                editGlance: { _ in },
                activateWatchface: { _ in },
                moveApplications: { _, _ in },
                detail: { application in Text(verbatim: application.displayName) }
            )
        }
    }
}
