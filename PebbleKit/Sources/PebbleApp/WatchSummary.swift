import PebbleProtocol
import Foundation

/// One watch as the Devices screens show it, whether it is connected now or
/// only remembered.
///
/// A screen that took `AppModel` and a watch id had to ask three questions —
/// connected? saved? which of the two is newer? — before it could draw a row.
/// This answers them once, where the model is at hand, so the layout has values.
struct WatchSummary: Identifiable, Equatable {
    var id: WatchID
    var name: String
    var model: WatchModel?
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
    init(watchID: WatchID, model appModel: AppModel) {
        let connection = appModel.connections.first { $0.watch.id == watchID }
        let saved = appModel.watches.saved.first { $0.id == watchID }
        self.init(
            id: watchID,
            name: connection?.watch.name ?? saved?.name ?? watchID.rawValue,
            model: connection?.watch.model ?? saved?.model,
            serialNumber: connection?.watch.serialNumber ?? saved?.serialNumber,
            batteryLevel: connection?.watch.batteryLevel ?? saved?.lastBatteryLevel,
            firmwareVersion: connection?.watch.firmwareVersion ?? saved?.firmwareVersion,
            languageLocale: connection?.watch.languageLocale,
            isRunningRecoveryFirmware: connection?.watch.isRunningRecoveryFirmware == true,
            phase: connection?.phase,
            isSaved: saved != nil,
            automaticallyConnects: saved?.automaticallyConnects ?? false,
            isConnecting: appModel.connectingWatchIDs.contains(watchID),
            lastConnectedAt: saved?.lastConnectedAt
        )
    }
}
