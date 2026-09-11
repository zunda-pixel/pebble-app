public import PebbleProtocol
import Defaults
// `storeEntry(for:)` is public and takes a UUID, so Foundation has to be too.
public import Foundation
import SwiftUI

/// The remote application catalog.
extension AppModel {
    /// The store being browsed. The chosen identifier survives launches; a
    /// stored name no built-in matches falls back to the Pebble store.
    var selectedCatalogSource: CatalogSource {
        .named(Defaults[.catalogSourceID])
    }

    /// Switches the catalog to another store: its own cache, feed, index and
    /// search, all at once. The search is cleared rather than re-run — the old
    /// results were the other store's answers.
    public func setCatalogSource(_ id: String) async {
        guard Defaults[.catalogSourceID] != id else { return }
        Defaults[.catalogSourceID] = id
        clearCatalogSearch()
        catalog.applications = []
        await loadCatalog()
        if catalog.applications.isEmpty { await refreshCatalog() }
    }

    public func loadCatalog() async {
        do {
            let snapshot = try await appCatalog.cachedSnapshot(source: selectedCatalogSource)
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
            let snapshot = try await appCatalog.update(
                model: connectedWatch?.model,
                source: selectedCatalogSource
            )
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

    /// Asks the store's whole index, not the fetched home feed: the feed is a
    /// shop window, and most of the store is only reachable this way (#97).
    ///
    /// A new search replaces the old results; the next page of the same one is
    /// `loadMoreCatalogSearchResults`.
    public func searchCatalog(_ query: String, kind: WatchApplicationKind? = nil) async {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !catalog.isSearching else { return }
        catalog.isSearching = true
        defer { catalog.isSearching = false }
        do {
            let answer = try await appCatalog.search(
                words,
                kind: kind,
                page: 0,
                preferredHardware: connectedWatch?.model.compatibleApplicationVariants ?? [],
                source: selectedCatalogSource
            )
            catalog.searchResults = answer.applications
            catalog.searchQuery = words
            catalog.searchKind = kind
            catalog.searchTotalCount = answer.totalCount
            catalog.hasMoreSearchResults = answer.hasMore
            catalog.searchPage = 1
        } catch {
            catalog.feedback = .failure("The store could not be searched.")
            await PebbleDiagnostics.shared.record(
                .error,
                category: "catalog",
                message: "store search failed: \(String(reflecting: error))"
            )
        }
    }

    public func loadMoreCatalogSearchResults() async {
        guard let shown = catalog.searchResults, catalog.hasMoreSearchResults,
              !catalog.isSearching else { return }
        catalog.isSearching = true
        defer { catalog.isSearching = false }
        do {
            let answer = try await appCatalog.search(
                catalog.searchQuery,
                kind: catalog.searchKind,
                page: catalog.searchPage,
                preferredHardware: connectedWatch?.model.compatibleApplicationVariants ?? [],
                source: selectedCatalogSource
            )
            // Deduplicated on the identifier: the index can shift under the
            // pages, and the same application twice would be two rows with one
            // BlobDB fate.
            let known = Set(shown.map(\.id))
            catalog.searchResults = shown + answer.applications.filter { !known.contains($0.id) }
            catalog.searchTotalCount = answer.totalCount
            catalog.hasMoreSearchResults = answer.hasMore
            catalog.searchPage = answer.page + 1
        } catch {
            catalog.feedback = .failure("The store could not be searched.")
        }
    }

    /// Back to the home feed alone, as when no search has been made.
    public func clearCatalogSearch() {
        catalog.searchResults = nil
        catalog.searchQuery = ""
        catalog.searchKind = nil
        catalog.searchTotalCount = 0
        catalog.hasMoreSearchResults = false
        catalog.searchPage = 0
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
            // The connected watch's board, so a colour watch is answered colour
            // screenshots. The answer is cached per identifier for the session,
            // so a watch swapped mid-session keeps the earlier board's images
            // until the next launch — a smaller wrong than asking again on
            // every visit.
            let entry = try await appCatalog.application(
                uuid: applicationID,
                from: baseURL,
                hardware: connectedWatch?.model.compatibleApplicationVariants.first
            )
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
        // Against the store's own number for what was installed, where there is
        // one. The store's version and the package's label are not the same
        // fact — see `WatchApplication.storeVersion` — and comparing across the
        // two made a freshly installed release read as an update forever (#117).
        // The label is only the yardstick for something that came in as a file,
        // where it is the only version anybody has.
        return application.isNewer(than: installed.storeVersion ?? installed.versionLabel)
            ? .updateAvailable
            : .installed
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
            // Which store release this was, written onto the imported record.
            // The import itself only knows the package, and the package's own
            // label is not reliably the store's number (#117): without this,
            // the same release reads as an update again on the next check.
            if applications.libraryFeedback == nil,
               var imported = (applications.apps + applications.watchfaces)
                   .first(where: { $0.id == application.id }) {
                imported.storeVersion = application.version
                if let library = try? await applicationLibrary.upsert(imported) {
                    updateApplications(library)
                }
            }
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
