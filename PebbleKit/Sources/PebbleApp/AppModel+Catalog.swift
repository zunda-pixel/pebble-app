public import PebbleProtocol
import Defaults
import Foundation
import SwiftUI

/// The remote application catalog.
extension AppModel {
    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot()
            catalog.applications = snapshot?.applications ?? []
            catalog.lastUpdated = snapshot?.fetchedAt
        }
        catch { catalog.feedback = .failure("The app catalog cache could not be loaded.") }
    }

    public func updateCatalog(source: String) async {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https" else {
            catalog.feedback = .failure("Enter a valid HTTPS catalog URL.")
            return
        }
        guard !catalog.isUpdating else { return }
        catalog.isUpdating = true
        defer { catalog.isUpdating = false }
        do {
            let snapshot = try await appCatalog.update(from: url, model: connectedWatch?.model)
            catalog.applications = snapshot.applications
            catalog.lastUpdated = snapshot.fetchedAt
            Defaults[.catalogSource] = source
            catalog.feedback = .success("App catalog updated with \(catalog.applications.count) apps.")
        } catch {
            catalog.feedback = .failure(
                catalog.applications.isEmpty
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
        guard let installed = (applications.apps + applications.watchfaces).first(where: { $0.id == application.id }) else {
            return .available
        }
        return application.isNewer(than: installed.versionLabel) ? .updateAvailable : .installed
    }

    public func installCatalogApplication(_ application: CatalogApplication) async {
        guard application.downloadURL.scheme?.lowercased() == "https" else {
            catalog.feedback = .failure("The catalog provided an unsafe download URL.")
            return
        }
        if catalogInstallationState(for: application) == .incompatible {
            catalog.feedback = .failure("\(application.name) is not compatible with this watch.")
            return
        }
        guard catalog.installingApplicationID == nil else { return }
        catalog.installingApplicationID = application.id
        defer { catalog.installingApplicationID = nil }
        do {
            catalog.feedback = .progress("Downloading \(application.name)…")
            let packageURL = try await appCatalog.download(application)
            let decoded = try await Task.detached { try PBWPackageImporter.application(from: packageURL) }.value
            guard decoded.id == application.id else { throw AppCatalogError.applicationIDMismatch }
            applications.libraryFeedback = nil
            await importApplication(from: packageURL)
            try? FileManager.default.removeItem(at: packageURL)
            // The import speaks for itself when it went wrong; only the
            // success is this screen's to word.
            catalog.feedback = applications.libraryFeedback ?? .success("\(application.name) installed.")
        } catch {
            catalog.feedback = .failure("The catalog package was rejected: \(error.localizedDescription)")
        }
    }

    public func installCatalogUpdates() async {
        let updates = catalog.applications.filter { catalogInstallationState(for: $0) == .updateAvailable }
        guard !updates.isEmpty else {
            catalog.feedback = .success("Installed apps are up to date.")
            return
        }
        for application in updates {
            await installCatalogApplication(application)
            if applications.libraryFeedback != nil { return }
        }
        catalog.feedback = .success("Installed \(updates.count) catalog update(s).")
    }
}
