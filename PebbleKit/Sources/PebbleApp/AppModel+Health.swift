import PebbleProtocol
public import Foundation
import SwiftUI

/// Health samples, and their exchange with HealthKit.
extension AppModel {
    public func loadHealth() async {
        do { healthSamples = try await healthStore.samples() }
        catch { healthFeedback = .failure("Health data could not be loaded.") }
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
            try await connection.client.send(HealthSyncCodec.requestFrame(since: healthSamples.map(\.date).max()))
            healthFeedback = .progress("Health synchronization requested.")
        } catch { healthFeedback = .failure("Health synchronization will retry after reconnection.") }
    }

    #if os(iOS)
    public func synchronizeWithHealthKit() async {
        do {
            try await healthKitBridge.synchronize(healthSamples)
            healthFeedback = .success("Health data synchronized with HealthKit.")
        } catch { healthFeedback = .failure("HealthKit access or synchronization failed.") }
    }

    public func importFromHealthKit() async {
        do {
            healthSamples = try await healthStore.merge(try await healthKitBridge.readRecentSamples())
            healthFeedback = .success("HealthKit data imported and deduplicated.")
        } catch { healthFeedback = .failure("HealthKit data could not be read.") }
    }
    #endif

    public func exportHealthData() async {
        do { healthExportURL = try await healthStore.export() }
        catch { healthFeedback = .failure("Health data could not be exported.") }
    }

    public func importHealthData(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            healthSamples = try await healthStore.importArchive(from: url)
            healthFeedback = .success("Health archive imported and reconciled.")
        } catch {
            healthFeedback = .failure("The selected health archive is invalid or unsupported.")
        }
    }

    public func deleteHealthData() async {
        try? await healthStore.deleteAll()
        healthSamples = []
        healthExportURL = nil
        healthFeedback = .success("Local Pebble health data deleted.")
    }
}
