public import PebbleProtocol
public import Foundation
import Retry
import SwiftUI

extension AppModel {
    public func languagePacks(deviceID: String? = nil) -> [PebbleLanguagePack] {
        guard let board = board(for: deviceID) else { return [] }
        return PebbleLanguagePackCatalog.packs(for: board)
    }

    // Fetched before the watch is asked for anything: finding out afterwards that
    // it went away beats holding a transfer open through a download.
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
        // A watch that says it takes no language packs would file the transfer and
        // never read it, and recovery firmware refuses files outright.
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
            // The watch does not restart: it notices the file, reloads it and says so on
            // its own screen. Nothing it reports about itself changes until it is asked.
            languageStatusMessage = "\(name) is installed. The watch switches to it now."
            await confirmLanguageChange(on: connection)
        } catch {
            languageStatusMessage = "\(name) could not be installed. \(error.localizedDescription)"
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
            try? await connection.client.refreshDeviceInformation()
        }
    }
}
