import API
import Foundation
import Retry
import SwiftUI

/// The language the watch shows its own menus and notifications in.
///
/// The firmware ships English and reads any other language from a pack stored
/// under the name `lang`. Installing one is a file transfer followed by an
/// install command, after which the watch restarts into the new language.
extension AppModel {
    /// The packs on offer for a watch, or nothing when it is not a watch this
    /// app knows the board of.
    public func languagePacks(deviceID: String? = nil) -> [PebbleLanguagePack] {
        guard let board = board(for: deviceID) else { return [] }
        return PebbleLanguagePackCatalog.packs(for: board)
    }

    /// Fetches a pack and sends it, in that order: the download needs only the
    /// network, and finding out afterwards that the watch went away is better
    /// than holding a transfer open while megabytes arrive.
    public func installLanguagePack(_ pack: PebbleLanguagePack, deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            languageStatusMessage = "Connect the watch to change its language."
            return
        }
        isInstallingLanguagePack = true
        defer { isInstallingLanguagePack = false }
        languageStatusMessage = "Downloading \(pack.localName)…"
        let data: Data
        do {
            data = try await languagePackCatalog.download(pack)
        } catch {
            languageStatusMessage = "\(pack.localName) could not be downloaded right now."
            return
        }
        await send([UInt8](data), named: pack.localName, on: connection)
    }

    /// Sends a pack the reader chose from a file, which is how a language the
    /// list does not carry gets onto a watch.
    public func installLanguagePack(from url: URL, deviceID: String? = nil) async {
        guard let connection = connection(for: deviceID), connection.isConnected else {
            languageStatusMessage = "Connect the watch to change its language."
            return
        }
        isInstallingLanguagePack = true
        defer { isInstallingLanguagePack = false }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            languageStatusMessage = "That language pack could not be read."
            return
        }
        guard !data.isEmpty else {
            languageStatusMessage = "That language pack could not be read."
            return
        }
        await send([UInt8](data), named: url.deletingPathExtension().lastPathComponent, on: connection)
    }

    private func send(_ bytes: [UInt8], named name: String, on connection: WatchConnection) async {
        // A watch that says it takes no language packs would file the transfer
        // and never read it, and recovery firmware refuses files outright.
        guard connection.device.supportsLanguagePacks || connection.device.capabilities == 0,
              !connection.device.isRunningRecoveryFirmware else {
            languageStatusMessage = "This watch cannot take a language pack."
            return
        }
        languageStatusMessage = "Sending \(name) to the watch…"
        applicationTransferDeviceID = connection.device.id
        connection.beginTransfer()
        defer {
            applicationTransferDeviceID = nil
            connection.endTransfer()
        }
        do {
            try await retry(with: .watchWork) {
                try await connection.client.installFile(bytes, filename: PebbleLanguagePackCatalog.filename)
            }
            languageStatusMessage = "\(name) is installed. The watch restarts to use it."
        } catch {
            languageStatusMessage = "\(name) could not be installed. \(error.localizedDescription)"
        }
    }
}
