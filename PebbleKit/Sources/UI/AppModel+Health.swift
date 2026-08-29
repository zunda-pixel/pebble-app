import API
import Foundation
import SwiftUI

/// Health samples, and their exchange with HealthKit.
extension AppModel {
    public func loadHealth() async {
        do { healthSamples = try await healthLibrary.samples() }
        catch { dataSyncStatusMessage = "Health data could not be loaded." }
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
            dataSyncStatusMessage = "Health synchronization requested."
        } catch { dataSyncStatusMessage = "Health synchronization will retry after reconnection." }
    }

    #if os(iOS)
    public func synchronizeWithHealthKit() async {
        do {
            try await healthKitBridge.synchronize(healthSamples)
            dataSyncStatusMessage = "Health data synchronized with HealthKit."
        } catch { dataSyncStatusMessage = "HealthKit access or synchronization failed." }
    }

    public func importFromHealthKit() async {
        do {
            healthSamples = try await healthLibrary.merge(try await healthKitBridge.readRecentSamples())
            dataSyncStatusMessage = "HealthKit data imported and deduplicated."
        } catch { dataSyncStatusMessage = "HealthKit data could not be read." }
    }
    #endif

    public func exportHealthData() async {
        do { healthExportURL = try await healthLibrary.export() }
        catch { dataSyncStatusMessage = "Health data could not be exported." }
    }

    public func importHealthData(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            healthSamples = try await healthLibrary.importArchive(from: url)
            dataSyncStatusMessage = "Health archive imported and reconciled."
        } catch {
            dataSyncStatusMessage = "The selected health archive is invalid or unsupported."
        }
    }

    public func deleteHealthData() async {
        try? await healthLibrary.deleteAll()
        healthSamples = []
        healthExportURL = nil
        dataSyncStatusMessage = "Local Pebble health data deleted."
    }
}
