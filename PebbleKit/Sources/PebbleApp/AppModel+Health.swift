import PebbleProtocol
public import Foundation
import SwiftUI

/// Health samples, and their exchange with HealthKit.
extension AppModel {
    public func loadHealth() async {
        do { health.samples = try await healthStore.samples() }
        catch { health.feedback = .failure("Health data could not be loaded.") }
    }

    public func requestHealthSync() async {
        for connection in activeConnections {
            await requestHealthSync(on: connection)
        }
    }

    func requestHealthSync(on connection: WatchConnection) async {
        do {
            try await connection.client.send(HealthDataLoggingCodec.reportOpenSessionsFrame())
            try await connection.client.send(HealthSyncCodec.requestFrame(since: health.samples.map(\.date).max()))
            health.feedback = .progress("Health synchronization requested.")
        } catch { health.feedback = .failure("Health synchronization will retry after reconnection.") }
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
