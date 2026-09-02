import API
import Foundation

/// One watch as the Devices screens show it, whether it is connected now or
/// only remembered.
///
/// A screen that took `AppModel` and a watch id had to ask three questions —
/// connected? saved? which of the two is newer? — before it could draw a row.
/// This answers them once, where the model is at hand, so the layout has values.
struct WatchSummary: Identifiable, Equatable {
    var id: String
    var name: String
    var model: PebbleWatchModel?
    var serialNumber: String?
    var batteryLevel: Int?
    var firmwareVersion: String?
    var languageLocale: String?
    var isRunningRecoveryFirmware: Bool = false
    var phase: WatchConnectionPhase?
    var isSaved: Bool = false
    var automaticallyConnects: Bool = false
    var isConnecting: Bool = false
    var lastConnectedAt: Date?

    var isConnected: Bool { phase == .connected }
}

extension WatchSummary {
    @MainActor
    init(watchID: String, model appModel: AppModel) {
        let connection = appModel.connections.first { $0.device.id == watchID }
        let saved = appModel.savedWatches.first { $0.id == watchID }
        self.init(
            id: watchID,
            name: connection?.device.name ?? saved?.name ?? watchID,
            model: connection?.device.model ?? saved?.model,
            serialNumber: connection?.device.serialNumber ?? saved?.serialNumber,
            batteryLevel: connection?.device.batteryLevel ?? saved?.lastBatteryLevel,
            firmwareVersion: connection?.device.firmwareVersion ?? saved?.firmwareVersion,
            languageLocale: connection?.device.languageLocale,
            isRunningRecoveryFirmware: connection?.device.isRunningRecoveryFirmware == true,
            phase: connection?.phase,
            isSaved: saved != nil,
            automaticallyConnects: saved?.automaticallyConnects ?? false,
            isConnecting: appModel.connectingDeviceIDs.contains(watchID),
            lastConnectedAt: saved?.lastConnectedAt
        )
    }
}
