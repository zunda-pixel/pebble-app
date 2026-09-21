public import Foundation
import PebbleProtocol
import SwiftUI

extension AppModel {
    /// Takes a URL the system opened the app with. Navigation happens at once;
    /// a package is fetched, read and held up for the reader to confirm —
    /// nothing a link carries reaches a watch on the link's say-so alone.
    public func openDeepLink(_ url: URL) async {
        switch PebbleDeepLink.parse(url) {
        case .failure(let refusal):
            deepLinks.feedback = .failure(refusalMessage(refusal))
            // The scheme and host only: a link can carry a token in its path,
            // and the diagnostics file leaves the app.
            await DiagnosticLog.shared.record(
                .info,
                category: "deeplink",
                message: "refused a link to \(url.scheme ?? "?")://\(url.host() ?? "")"
            )
        case .success(.section(let section)):
            deepLinks.requestedSection = section
        case .success(.storeApplication(let id)):
            await presentStoreApplication(id: id)
        case .success(.package(let kind, let source)):
            await prepareDeepLinkPackage(kind, from: source)
        }
    }

    private func refusalMessage(_ refusal: PebbleDeepLink.Refusal) -> LocalizedStringKey {
        switch refusal {
        case .unknown:
            "This link is not one the app knows."
        case .insecurePackageSource:
            "The package link is not https, so what arrives could differ from what was linked."
        case .storeFeedsNotSupported:
            "Adding store feeds by link is not supported yet."
        case .accountsNotSupported:
            "Account links are not supported yet."
        case .configurationSessionOnly:
            "This link belongs to a settings page and only means something there."
        }
    }

    private func presentStoreApplication(id: String) async {
        deepLinks.isPreparing = true
        defer { deepLinks.isPreparing = false }
        do {
            guard let row = try await appCatalog.applications(
                ids: [id],
                source: selectedCatalogSource
            ).first else {
                deepLinks.feedback = .failure("The store does not list this application.")
                return
            }
            deepLinks.storeApplication = row
        } catch {
            deepLinks.feedback = .failure("The store could not be reached.")
            await DiagnosticLog.shared.record(
                .error,
                category: "deeplink",
                message: "store lookup failed: \(String(reflecting: error))"
            )
        }
    }

    private func prepareDeepLinkPackage(
        _ kind: PebbleDeepLink.PackageKind,
        from source: URL
    ) async {
        deepLinks.isPreparing = true
        defer { deepLinks.isPreparing = false }
        do {
            let local = try await copyPackage(from: source)
            var pending = PendingDeepLinkPackage(
                kind: kind,
                fileName: source.lastPathComponent,
                localURL: local,
                byteCount: fileSize(of: local) ?? 0
            )
            switch kind {
            case .watchApp:
                // The importer's own reading, so a file that is not a watch app
                // is refused here rather than after the reader said install.
                let application = try await Task.detached(priority: .userInitiated) {
                    try PBWPackageImporter.application(from: local)
                }.value
                pending.title = application.longName
                pending.subtitle = "\(application.companyName) · \(application.versionLabel)"
            case .firmware:
                // Fully judged against the watch's own board at install; here
                // the manifest is read only so the sheet can say what it is,
                // and only when a connected watch names the board to read for.
                if let board = connectedWatch?.board,
                   let package = try? PBZFirmwareImporter.load(from: local, board: board) {
                    pending.title = package.manifest.firmware.versionTag
                    pending.subtitle = package.manifest.firmware.hardwareRevision
                }
            case .languagePack:
                break
            }
            // Replacing an earlier offer, whose copy would otherwise be orphaned.
            if let replaced = deepLinks.pendingPackage {
                try? FileManager.default.removeItem(at: replaced.localURL)
            }
            deepLinks.pendingPackage = pending
        } catch {
            deepLinks.feedback = .failure("The linked package could not be read.")
            await DiagnosticLog.shared.record(
                .error,
                category: "deeplink",
                message: "package fetch failed: \(String(reflecting: error))"
            )
        }
    }

    /// The app's own copy: what was inspected is what will be installed.
    private func copyPackage(from source: URL) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "deeplink-\(UUID().uuidString)-\(source.lastPathComponent)")
        if source.isFileURL {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw DeepLinkPackageError.notFound
            }
            // Far above any real package — a firmware is a few megabytes — and
            // far below what a hostile link could ask this phone to hold.
            guard let size = fileSize(of: downloaded), size <= 32 * 1_024 * 1_024 else {
                try? FileManager.default.removeItem(at: downloaded)
                throw DeepLinkPackageError.tooLarge
            }
            try FileManager.default.moveItem(at: downloaded, to: destination)
        }
        return destination
    }

    private func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path()))?[.size] as? Int
    }

    /// The reader looked at the sheet and said install: from here the package
    /// takes the same path a file chosen in the importer takes, checks and all.
    public func confirmPendingDeepLinkPackage() async {
        guard let pending = deepLinks.pendingPackage else { return }
        deepLinks.pendingPackage = nil
        switch pending.kind {
        case .watchApp:
            deepLinks.requestedSection = .apps
            await importApplication(from: pending.localURL)
        case .firmware:
            deepLinks.requestedSection = .watches
            await installFirmware(from: pending.localURL)
        case .languagePack:
            await installLanguagePack(from: pending.localURL)
        }
        try? FileManager.default.removeItem(at: pending.localURL)
    }

    public func dismissPendingDeepLinkPackage() {
        guard let pending = deepLinks.pendingPackage else { return }
        deepLinks.pendingPackage = nil
        try? FileManager.default.removeItem(at: pending.localURL)
    }

    public func dismissDeepLinkStoreApplication() {
        deepLinks.storeApplication = nil
    }

    public func clearDeepLinkFeedback() {
        deepLinks.feedback = nil
    }

    /// The root view took the navigation; asked-and-answered is put back to nil
    /// so the same section can be asked for again later.
    public func consumeRequestedDeepLinkSection() {
        deepLinks.requestedSection = nil
    }
}

enum DeepLinkPackageError: Error, Equatable {
    case notFound
    case tooLarge
}
