public import PebbleProtocol
import Defaults
// `storeEntry(for:)` is public and takes a UUID, so Foundation has to be too.
public import Foundation
import SwiftUI

/// The remote application catalog.
extension AppModel {
    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot()
            catalog.applications = snapshot?.applications ?? []
            catalog.sourceURL = snapshot?.sourceURL
            catalog.lastUpdated = snapshot?.fetchedAt
        }
        catch { catalog.feedback = .failure("The app catalog cache could not be loaded.") }
    }

    public func refreshCatalog() async {
        guard !catalog.isUpdating else { return }
        catalog.isUpdating = true
        defer { catalog.isUpdating = false }
        do {
            let snapshot = try await appCatalog.update(model: connectedWatch?.model)
            catalog.applications = snapshot.applications
            catalog.sourceURL = snapshot.sourceURL
            catalog.lastUpdated = snapshot.fetchedAt
            catalog.feedback = .success("App catalog updated with \(catalog.applications.count) apps.")
        } catch {
            catalog.feedback = .failure(
                catalog.applications.isEmpty
                    ? "The app catalog could not be updated."
                    : "Catalog refresh failed; showing the offline cache."
            )
        }
    }

    /// What the store knows about something already in the library.
    ///
    /// Asked by the package's own UUID, so it works for an application however
    /// it arrived: installed from the catalogue, or side-loaded from a file and
    /// listed in the store all the same. Nothing is stamped into the library at
    /// install time, so applications installed before this existed are covered
    /// too.
    ///
    /// The feed is consulted first, and the loaded catalogue usually has it, so
    /// most visits cost nothing.
    public func storeEntry(for applicationID: UUID) async -> CatalogApplication? {
        if let listed = catalog.applications.first(where: { $0.id == applicationID }) { return listed }
        guard !catalog.answeredStoreLookups.contains(applicationID) else {
            return catalog.storeEntries[applicationID]
        }
        // The store the loaded catalogue came from, which for a cache written
        // before the store moved is not today's. Asking the one the listing
        // came from is what makes the comparison mean anything.
        let baseURL = catalog.sourceURL ?? AppCatalog.defaultSourceURL
        guard baseURL.scheme?.lowercased() == "https" else { return nil }
        do {
            let entry = try await appCatalog.application(uuid: applicationID, from: baseURL)
            if let entry { catalog.storeEntries[applicationID] = entry }
            // Recorded whichever way it went: "the store does not have this"
            // is an answer, and asking again on every visit will not change it.
            catalog.answeredStoreLookups.insert(applicationID)
            return entry
        } catch {
            // The network refused rather than the store answering. Left
            // unrecorded, so a reader who reconnects and comes back gets it.
            return nil
        }
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

    /// Applications the store has a newer version of than the library does.
    ///
    /// Asked of the library rather than read off the loaded feed. That feed is
    /// `v1/home`, a page of what the store is featuring — 73 applications the
    /// day this was written — so anything installed from outside it was never
    /// offered an update at all, however far behind it had fallen.
    ///
    /// Each is looked up by the UUID in its own package, one at a time.
    /// `v1/apps/bulk` would be the way to ask about many, but measured, it
    /// answers only to the store's own identifiers: handed a library UUID it
    /// returns 200 with the UUID under `missing` and nothing in `data`. The
    /// library has no store identifiers to send it.
    ///
    /// Most of these cost nothing: `storeEntry(for:)` reads the loaded feed
    /// first, and remembers every answer including "no such application".
    public func catalogUpdates() async -> [CatalogApplication] {
        var updates: [CatalogApplication] = []
        for installed in applications.apps + applications.watchfaces {
            guard let listed = await storeEntry(for: installed.id),
                  catalogInstallationState(for: listed) == .updateAvailable
            else { continue }
            updates.append(listed)
        }
        return updates
    }

    /// Answers on the applications screen rather than the catalogue's.
    ///
    /// That is where the button lives, and the catalogue never showed this: it
    /// has no feedback banner, so the words went to `catalog.feedback` and only
    /// a detail screen would have shown them. The per-application progress
    /// `installCatalogApplication` writes still goes there, which is why each
    /// one is named here too.
    public func installCatalogUpdates() async {
        // Said before the asking, because asking the store about a library it
        // has not been asked about before is a round trip per application.
        applications.managementFeedback = .progress("Checking for updates…")
        let updates = await catalogUpdates()
        guard !updates.isEmpty else {
            applications.managementFeedback = .success("Installed apps are up to date.")
            return
        }
        for application in updates {
            applications.managementFeedback = .progress("Downloading \(application.name)…")
            await installCatalogApplication(application)
            if applications.libraryFeedback != nil { return }
        }
        applications.managementFeedback = .success("Installed \(updates.count) catalog update(s).")
    }
}
