import PebbleProtocol
import SwiftUI

/// The same screen, reached from the catalogue.
///
/// The store's copy is in hand here and the library is what has to be looked
/// up, which is the other way round from `ApplicationDetailView` — and needs
/// no network, because the library is already loaded.
struct CatalogApplicationDetailView: View {
    var application: CatalogApplication
    var model: AppModel
    /// Nil where no screen can host the glance editor — a deep link's sheet —
    /// which hides the row rather than showing a button that does nothing.
    var editGlance: ((WatchApplication) -> Void)?
    @Environment(\.dismiss) private var dismiss
    /// Why Remove did not. The catalogue screen this came from does not show
    /// the library's answers, so without this a refusal was shown nowhere.
    @State private var removalFeedback: FeatureFeedback?

    private var installed: WatchApplication? {
        model.applications.all.first { $0.id == application.id }
    }

    var body: some View {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(catalogEntry: application, installed: installed),
            isActive: model.applications.isActiveWatchface(application.id, on: nil),
            isInstalled: nil,
            installationState: model.catalogInstallationState(for: application),
            isInstalling: model.catalog.installingApplicationID == application.id,
            isAnyInstallRunning: model.catalog.installingApplicationID != nil,
            isOperationInProgress: model.isApplicationManagementBusy,
            feedback: removalFeedback ?? model.catalog.feedback(about: application.id),
            transfers: model.transfers(of: application.id),
            install: {
                removalFeedback = nil
                Task { await model.installCatalogApplication(application) }
            },
            configureApplication: {
                if let installed { Task { await model.configureApplication(installed) } }
            },
            editGlance: installed.flatMap { installed in
                editGlance.map { edit in { edit(installed) } }
            },
            activateWatchface: {
                if let installed { Task { await model.activateWatchface(installed) } }
            },
            removeApplication: {
                if let installed {
                    Task {
                        if await model.removeApplication(id: installed.id) {
                            dismiss()
                        } else {
                            removalFeedback = model.applications.libraryFeedback
                        }
                    }
                }
            }
        )
    }
}
