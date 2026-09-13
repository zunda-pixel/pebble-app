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
    var editGlance: (WatchApplication) -> Void
    @Environment(\.dismiss) private var dismiss

    private var installed: WatchApplication? {
        (model.applications.apps + model.applications.watchfaces).first { $0.id == application.id }
    }

    var body: some View {
        ApplicationDetailContent(
            subject: ApplicationDetailSubject(catalogEntry: application, installed: installed),
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
