public import PebbleProtocol
public import Foundation

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
        if let glances = try? await appGlanceStore.update(written) {
            appGlances.glances = glances
        }
        for connection in activeConnections {
            await synchronizeAppGlances(on: connection)
        }
    }

    func synchronizeAppGlances(on connection: WatchConnection) async {
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
            } catch {
                await PebbleDiagnostics.shared.record(
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
            } catch {
                await PebbleDiagnostics.shared.record(
                    .error,
                    category: "glance",
                    message: "\(connection.watch.name) kept a glance that is gone here: \(String(reflecting: error))"
                )
                return
            }
        }
    }
}
