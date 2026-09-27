public import PebbleProtocol
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func languagePacks(watchID: WatchID? = nil) -> [LanguagePack] {
        guard let board = board(for: watchID) else { return [] }
        return LanguagePackCatalog.packs(for: board)
    }

    // Fetched before the watch is asked for anything: finding out afterwards that
    // it went away beats holding a transfer open through a download.
    public func installLanguagePack(_ pack: LanguagePack, watchID: WatchID? = nil) async {
        guard !language.isInstalling else { return }
        guard let connection = connection(for: watchID), connection.isConnected else {
            language.feedback = .failure("Connect the watch to change its language.")
            return
        }
        language.isInstalling = true
        defer { language.isInstalling = false }
        language.feedback = .progress("Downloading \(pack.localName)…")
        let data: Data
        do {
            data = try await languagePackCatalog.download(pack)
        } catch {
            language.feedback = .failure("\(pack.localName) could not be downloaded right now.")
            return
        }
        await send([UInt8](data), named: pack.localName, on: connection)
    }

    public func installLanguagePack(from url: URL, watchID: WatchID? = nil) async {
        guard !language.isInstalling else { return }
        guard let connection = connection(for: watchID), connection.isConnected else {
            language.feedback = .failure("Connect the watch to change its language.")
            return
        }
        language.isInstalling = true
        defer { language.isInstalling = false }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            language.feedback = .failure("That language pack could not be read.")
            return
        }
        guard !data.isEmpty else {
            language.feedback = .failure("That language pack could not be read.")
            return
        }
        await send([UInt8](data), named: url.deletingPathExtension().lastPathComponent, on: connection)
    }

    private func send(_ bytes: [UInt8], named name: String, on connection: WatchConnection) async {
        // A watch that says it takes no language packs would file the transfer and
        // never read it, and recovery firmware refuses files outright.
        guard connection.watch.supportsLanguagePacks || connection.watch.capabilities == 0,
              !connection.watch.isRunningRecoveryFirmware else {
            language.feedback = .failure("This watch cannot take a language pack.")
            return
        }
        language.feedback = .progress("Sending \(name) to the watch…")
        connection.beginTransfer(.languagePack)
        defer {
            connection.endTransfer()
        }
        do {
            try await retry(with: .watchWork) {
                try await connection.client.installFile(bytes, filename: LanguagePackCatalog.filename)
            }
            // The watch does not restart: it notices the file, reloads it and says so on
            // its own screen. Nothing it reports about itself changes until it is asked.
            language.feedback = .success("\(name) is installed. The watch switches to it now.")
            await confirmLanguageChange(on: connection)
        } catch {
            language.feedback = .failure("\(name) could not be installed. \(failureReason(for: error))")
        }
    }
}

extension AppModel {
    // The firmware reloads the pack asynchronously, so the first answer can still
    // be the old locale.
    private func confirmLanguageChange(on connection: WatchConnection) async {
        for delay in [Duration.seconds(1), .seconds(3)] {
            try? await Task.sleep(for: delay)
            guard connection.isConnected else { return }
            try? await connection.client.refreshWatchInformation()
        }
    }
}
