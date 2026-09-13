public import PebbleProtocol
public import Foundation
// `FeatureFeedback` holds a `LocalizedStringKey`, whose literal initializer
// needs the module that declares it.
import SwiftUI

extension AppModel {
    func loadAppGlances() async {
        appGlances.glances = (try? await appGlanceStore.glances()) ?? []
    }

    public func glance(for applicationID: UUID) -> AppGlance? {
        appGlances.glances.first { $0.applicationID == applicationID }
    }

    /// Writes the line, or takes it away when nothing is left of it.
    public func setAppGlance(_ glance: AppGlance) async {
        var written = glance
        written.slices.removeAll { $0.subtitleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // The watch refuses a glance that is not newer than the one it holds,
        // and the reader saving the same words twice still means "show this".
        written.updatedAt = .now
        guard let glances = try? await appGlanceStore.update(written) else {
            // Was a `try?` with nothing after it: the line was not kept and
            // the screen showed the reader their own words back.
            appGlances.feedback = .failure("The launcher line could not be saved.")
            return
        }
        appGlances.glances = glances
        for connection in activeConnections {
            await synchronizeAppGlances(on: connection)
        }
        // True whether a watch is connected or not: `synchronizeAppGlances` is
        // run again for each connection as it is made.
        appGlances.feedback = .success("Launcher line saved. A Pebble that is not connected is told when it connects.")
    }

    func synchronizeAppGlances(on connection: WatchConnection) async {
        var taken = 0
        var dropped = 0
        for glance in appGlances.glances {
            // A glance for an app the watch does not have is refused, and
            // asking is how this app finds out — but a watch that has not
            // finished telling us what it holds would refuse everything.
            guard applications.installedIDsByWatch[connection.watch.id]?.contains(glance.applicationID) != false else {
                continue
            }
            let value = AppGlanceCodec.value(for: glance)
            guard connection.synchronizedAppGlances[glance.applicationID] != value else { continue }
            do {
                try await connection.client.write(.appGlance(glance))
                connection.synchronizedAppGlances[glance.applicationID] = value
                taken += 1
            } catch {
                await DiagnosticLog.shared.record(
                    .error,
                    category: "glance",
                    message: "\(connection.watch.name) would not take a glance: \(String(reflecting: error))"
                )
                return
            }
        }
        // A glance the reader deleted is one the watch is still showing.
        for applicationID in connection.synchronizedAppGlances.keys
        where !appGlances.glances.contains(where: { $0.applicationID == applicationID }) {
            do {
                try await connection.client.remove(.appGlance(applicationID: applicationID))
                connection.synchronizedAppGlances[applicationID] = nil
                dropped += 1
            } catch {
                await DiagnosticLog.shared.record(
                    .error,
                    category: "glance",
                    message: "\(connection.watch.name) kept a glance that is gone here: \(String(reflecting: error))"
                )
                return
            }
        }
        // Nothing to say when nothing changed: this runs on every connection, and
        // a glance already on the watch is skipped above.
        guard taken + dropped > 0 else { return }
        await DiagnosticLog.shared.record(
            category: "glance",
            message: "\(connection.watch.name) took \(taken) glance(s) and dropped \(dropped)"
        )
    }
}
