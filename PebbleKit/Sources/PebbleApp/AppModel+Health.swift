import PebbleProtocol
public import Foundation
import SwiftUI

/// Health samples, and their exchange with HealthKit.
extension AppModel {
    public func loadHealth() async {
        do { health.samples = try await healthStore.samples() }
        catch { health.feedback = .failure("Health data could not be loaded.") }
    }

    /// The Synchronize button: the reader asking, so the watch's answer is
    /// theirs to see.
    public func requestHealthSync() async {
        isHealthSyncRequestedByReader = true
        for connection in activeConnections {
            do {
                try await sendHealthSyncRequest(on: connection)
                health.feedback = .progress("Health synchronization requested.")
            } catch {
                health.feedback = .failure("Health synchronization will retry after reconnection.")
            }
        }
    }

    /// The one every connect sends. Nobody asked for it on this side, so it
    /// writes to the log and leaves the Health screen's banner alone: a
    /// "requested" that the watch never answered sat there for good.
    func requestHealthSync(on connection: WatchConnection) async {
        do {
            try await sendHealthSyncRequest(on: connection)
        } catch {
            await DiagnosticLog.shared.record(
                .warning,
                category: "health",
                message: "\(connection.watch.name) was not asked for its health data: \(String(reflecting: error))"
            )
        }
    }

    private func sendHealthSyncRequest(on connection: WatchConnection) async throws {
        try await connection.client.send(HealthDataLoggingCodec.reportOpenSessionsFrame())
        try await connection.client.send(HealthSyncCodec.requestFrame(since: health.samples.map(\.date).max()))
    }

    /// Where something the watch sent about its health is said: on the Health
    /// screen when the reader asked for it, in the log otherwise.
    func reportHealth(_ feedback: FeatureFeedback, logging message: String) async {
        if isHealthSyncRequestedByReader {
            health.feedback = feedback
        } else {
            await DiagnosticLog.shared.record(
                feedback.isFailure ? .error : .info,
                category: "health",
                message: message
            )
        }
    }

    #if os(iOS)
    public func synchronizeWithHealthKit() async {
        do {
            try await healthKitBridge.synchronize(health.samples)
            health.feedback = .success("Health data synchronized with HealthKit.")
        } catch { health.feedback = .failure("HealthKit access or synchronization failed.") }
    }

    public func importFromHealthKit() async {
        do {
            health.samples = try await healthStore.merge(try await healthKitBridge.readRecentSamples())
            health.feedback = .success("HealthKit data imported and deduplicated.")
        } catch { health.feedback = .failure("HealthKit data could not be read.") }
    }
    #endif

    /// Writes every recorded day to one file and hands back where it went.
    ///
    /// Answers to its caller rather than to the health screen's banner: the
    /// sheet that asks for this is where the reader is looking, and is what
    /// shows both the file and a failure. Kept on the model too, so reopening
    /// that sheet finds the last export still there to share.
    @discardableResult
    public func exportHealthData() async -> URL? {
        do {
            let url = try await healthStore.export()
            health.exportURL = url
            return url
        } catch {
            return nil
        }
    }

    public func importHealthData(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            health.samples = try await healthStore.importArchive(from: url)
            health.feedback = .success("Health archive imported and reconciled.")
        } catch {
            health.feedback = .failure("The selected health archive is invalid or unsupported.")
        }
    }

    public func deleteHealthData() async {
        do {
            try await healthStore.deleteAll()
        } catch {
            health.feedback = .failure("Local Pebble health data could not be deleted.")
            return
        }
        health.samples = []
        health.exportURL = nil
        health.feedback = .success("Local Pebble health data deleted.")
    }
}
