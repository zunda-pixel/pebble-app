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
        guard !activeConnections.isEmpty else { return }
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

    public func exportHealthData() async {
        do { health.exportURL = try await healthStore.export() }
        catch { health.feedback = .failure("Health data could not be exported.") }
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
        try? await healthStore.deleteAll()
        health.samples = []
        health.exportURL = nil
        health.feedback = .success("Local Pebble health data deleted.")
    }
}
