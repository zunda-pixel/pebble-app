import API
import Defaults
import Foundation

/// The remote application catalog.
extension AppModel {
    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot()
            catalogApplications = snapshot?.applications ?? []
            catalogLastUpdated = snapshot?.fetchedAt
        }
        catch { dataSyncStatusMessage = "The app catalog cache could not be loaded." }
    }

    public func updateCatalog(source: String) async {
        guard let url = URL(string: source), url.scheme?.lowercased() == "https" else {
            dataSyncStatusMessage = "Enter a valid HTTPS catalog URL."
            return
        }
        guard !isUpdatingCatalog else { return }
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        do {
            let snapshot = try await appCatalog.update(from: url, model: connectedDevice?.model)
            catalogApplications = snapshot.applications
            catalogLastUpdated = snapshot.fetchedAt
            Defaults[.catalogSource] = source
            dataSyncStatusMessage = "App catalog updated with \(catalogApplications.count) apps."
        } catch {
            dataSyncStatusMessage = catalogApplications.isEmpty
                ? "The app catalog could not be updated."
                : "Catalog refresh failed; showing the offline cache."
        }
    }

    public func refreshCatalog() async {
        let source = Defaults[.catalogSource] ?? PebbleAppCatalog.defaultSourceURL.absoluteString
        await updateCatalog(source: source)
    }

    public func catalogInstallationState(for application: PebbleCatalogApplication) -> CatalogInstallationState {
        if !connectedDevices.isEmpty,
           !connectedDevices.contains(where: { application.supports($0.model) }) {
            return .incompatible
        }
        guard let installed = (watchApplications + watchfaces).first(where: { $0.id == application.id }) else {
            return .available
        }
        return application.isNewer(than: installed.versionLabel) ? .updateAvailable : .installed
    }

    public func installCatalogApplication(_ application: PebbleCatalogApplication) async {
        guard application.downloadURL.scheme?.lowercased() == "https" else {
            dataSyncStatusMessage = "The catalog provided an unsafe download URL."
            return
        }
        if catalogInstallationState(for: application) == .incompatible {
            dataSyncStatusMessage = "\(application.name) is not compatible with this watch."
            return
        }
        guard installingCatalogApplicationID == nil else { return }
        installingCatalogApplicationID = application.id
        defer { installingCatalogApplicationID = nil }
        do {
            dataSyncStatusMessage = "Downloading \(application.name)…"
            let packageURL = try await appCatalog.download(application)
            let decoded = try await Task.detached { try PBWPackageImporter.application(from: packageURL) }.value
            guard decoded.id == application.id else { throw AppCatalogError.applicationIDMismatch }
            applicationLibraryErrorMessage = nil
            await importApplication(from: packageURL)
            try? FileManager.default.removeItem(at: packageURL)
            dataSyncStatusMessage = applicationLibraryErrorMessage == nil
                ? "\(application.name) installed."
                : applicationLibraryErrorMessage
        } catch {
            dataSyncStatusMessage = "The catalog package was rejected: \(error.localizedDescription)"
        }
    }

    public func installCatalogUpdates() async {
        let updates = catalogApplications.filter { catalogInstallationState(for: $0) == .updateAvailable }
        guard !updates.isEmpty else {
            dataSyncStatusMessage = "Installed apps are up to date."
            return
        }
        for application in updates {
            await installCatalogApplication(application)
            if applicationLibraryErrorMessage != nil { return }
        }
        dataSyncStatusMessage = "Installed \(updates.count) catalog update(s)."
    }
}
