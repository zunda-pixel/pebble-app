public import PebbleProtocol
import Defaults
import Foundation
import SwiftUI

/// The remote application catalog.
extension AppModel {
    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot()
            catalogApplications = snapshot?.applications ?? []
            catalogLastUpdated = snapshot?.fetchedAt
        }
        catch { catalogFeedback = .failure("The app catalog cache could not be loaded.") }
    }

    public func updateCatalog(source: String) async {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https" else {
            catalogFeedback = .failure("Enter a valid HTTPS catalog URL.")
            return
        }
        guard !isUpdatingCatalog else { return }
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        do {
            let snapshot = try await appCatalog.update(from: url, model: connectedWatch?.model)
            catalogApplications = snapshot.applications
            catalogLastUpdated = snapshot.fetchedAt
            Defaults[.catalogSource] = source
            catalogFeedback = .success("App catalog updated with \(catalogApplications.count) apps.")
        } catch {
            catalogFeedback = .failure(
                catalogApplications.isEmpty
                    ? "The app catalog could not be updated."
                    : "Catalog refresh failed; showing the offline cache."
            )
        }
    }

    public func refreshCatalog() async {
        let source = Defaults[.catalogSource] ?? AppCatalog.defaultSourceURL.absoluteString
        await updateCatalog(source: source)
    }

    public func catalogInstallationState(for application: CatalogApplication) -> CatalogInstallationState {
        if !connectedWatches.isEmpty,
           !connectedWatches.contains(where: { application.supports($0.model) }) {
            return .incompatible
        }
        guard let installed = (watchApplications + watchfaces).first(where: { $0.id == application.id }) else {
            return .available
        }
        return application.isNewer(than: installed.versionLabel) ? .updateAvailable : .installed
    }

    public func installCatalogApplication(_ application: CatalogApplication) async {
        guard application.downloadURL.scheme?.lowercased() == "https" else {
            catalogFeedback = .failure("The catalog provided an unsafe download URL.")
            return
        }
        if catalogInstallationState(for: application) == .incompatible {
            catalogFeedback = .failure("\(application.name) is not compatible with this watch.")
            return
        }
        guard installingCatalogApplicationID == nil else { return }
        installingCatalogApplicationID = application.id
        defer { installingCatalogApplicationID = nil }
        do {
            catalogFeedback = .progress("Downloading \(application.name)…")
            let packageURL = try await appCatalog.download(application)
            let decoded = try await Task.detached { try PBWPackageImporter.application(from: packageURL) }.value
            guard decoded.id == application.id else { throw AppCatalogError.applicationIDMismatch }
            applicationLibraryFeedback = nil
            await importApplication(from: packageURL)
            try? FileManager.default.removeItem(at: packageURL)
            // The import speaks for itself when it went wrong; only the
            // success is this screen's to word.
            catalogFeedback = applicationLibraryFeedback ?? .success("\(application.name) installed.")
        } catch {
            catalogFeedback = .failure("The catalog package was rejected: \(error.localizedDescription)")
        }
    }

    public func installCatalogUpdates() async {
        let updates = catalogApplications.filter { catalogInstallationState(for: $0) == .updateAvailable }
        guard !updates.isEmpty else {
            catalogFeedback = .success("Installed apps are up to date.")
            return
        }
        for application in updates {
            await installCatalogApplication(application)
            if applicationLibraryFeedback != nil { return }
        }
        catalogFeedback = .success("Installed \(updates.count) catalog update(s).")
    }
}
