public import Foundation

@MainActor
public final class MockPebbleClient: PebbleClient {
    public private(set) var sentFrames: [PebbleProtocolFrame] = []
    public private(set) var sentAppMessages: [AppMessageData] = []
    public private(set) var appMessageResponses: [(transactionID: UInt8, acknowledged: Bool)] = []
    public private(set) var reorderedApplicationIDs: [[UUID]] = []
    public private(set) var sentNotifications: [PebbleTimelineNotification] = []
    public private(set) var timelinePins: [PebbleTimelinePin] = []
    public private(set) var installedObjects: [(bytes: [UInt8], objectType: PutBytesObjectType, appBankID: UInt32)] = []
    public private(set) var installedFirmwarePackages: [PBZFirmwarePackage] = []
    public private(set) var installedFiles: [(bytes: [UInt8], filename: String)] = []
    public private(set) var writtenWeather: [PebbleWeatherReport] = []
    public private(set) var timelineReminders: [PebbleTimelinePin] = []
    public private(set) var writtenWeatherLocationOrder: [UUID] = []
    public private(set) var writtenWatchSettings: [WatchSetting: Bool] = [:]
    public private(set) var writtenActivitySettings: PebbleActivitySettings?
    public private(set) var writtenHeartRateSettings: PebbleHeartRateSettings?
    public private(set) var writtenHealthDays: [PebbleHealthDay] = []
    public private(set) var writtenReminderAppState: PebbleReminderAppState?
    public private(set) var writtenNotificationSourceApps: [NotificationSourceApp] = []
    public private(set) var registeredApplications: [PebbleAppMetadata] = []
    public private(set) var unregisteredApplicationIDs: [UUID] = []
    public private(set) var disconnectedDevices: [PebbleDevice] = []
    private var nextTransactionID: UInt8 = 0
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?

    public init() {}

    public func scan() async throws -> [DiscoveredPebble] {
        try await Task.sleep(for: .milliseconds(400))

        return [
            DiscoveredPebble(
                id: "mock-flint",
                name: "Pebble 2 Duo",
                model: .pebble2Duo,
                signalStrength: -42
            ),
            DiscoveredPebble(
                id: "mock-emery",
                name: "Pebble Time 2",
                model: .pebbleTime2,
                signalStrength: -57
            ),
            DiscoveredPebble(
                id: "mock-gabbro",
                name: "Pebble Round 2",
                model: .pebbleRound2,
                signalStrength: -68
            ),
        ]
    }

    public func retrieveKnownDevices(_ hints: [DiscoveredPebble]) async throws -> [DiscoveredPebble] {
        hints
    }

    /// Makes the next connection report a watch running recovery firmware.
    public var connectsAsRecoveryFirmware = false

    public func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        try await Task.sleep(for: .milliseconds(500))

        return PebbleDevice(
            id: device.id,
            name: device.name,
            model: device.model,
            firmwareVersion: "v5.0.0-mock",
            batteryLevel: 84,
            serialNumber: "MOCK00000001",
            isRunningRecoveryFirmware: connectsAsRecoveryFirmware
        )
    }

    public func disconnect(from device: PebbleDevice) async {
        disconnectedDevices.append(device)
        await Task.yield()
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        sentFrames.append(frame)
    }

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in
            frameContinuation = continuation
        }
    }

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {}

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        reorderedApplicationIDs.append(applicationIDs)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {}

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        sentAppMessages.append(AppMessageData(
            transactionID: nextTransactionID,
            applicationID: applicationID,
            tuples: tuples
        ))
        nextTransactionID &+= 1
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        appMessageResponses.append((transactionID, acknowledged))
    }

    public func sendNotification(_ notification: PebbleTimelineNotification) async throws {
        sentNotifications.append(notification)
    }

    public func upsertTimelinePin(_ pin: PebbleTimelinePin) async throws {
        timelinePins.removeAll { $0.id == pin.id }
        timelinePins.append(pin)
    }

    public func deleteTimelinePin(id: UUID) async throws {
        timelinePins.removeAll { $0.id == id }
    }

    public func launchApplication(id: UUID) async throws {
        eventContinuation?.yield(.appRunStateChanged(.started(id)))
    }

    public func emit(_ frame: PebbleProtocolFrame) {
        frameContinuation?.yield(frame)
    }

    public func emit(_ event: PebbleClientEvent) {
        eventContinuation?.yield(event)
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        installedObjects.append((bytes, objectType, appBankID))
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        installedFirmwarePackages.append(package)
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        installedFiles.append((bytes, filename))
    }

    public func writeNotificationSourceApp(_ app: NotificationSourceApp) async throws {
        writtenNotificationSourceApps.removeAll { $0.bundleID == app.bundleID }
        writtenNotificationSourceApps.append(app)
    }

    public func removeNotificationSourceApp(bundleID: String) async throws {
        writtenNotificationSourceApps.removeAll { $0.bundleID == bundleID }
    }

    public func upsertTimelineReminder(_ reminder: PebbleTimelinePin) async throws {
        timelineReminders.removeAll { $0.id == reminder.id }
        timelineReminders.append(reminder)
    }

    public func deleteTimelineReminder(id: UUID) async throws {
        timelineReminders.removeAll { $0.id == id }
    }

    public func writeWeather(_ report: PebbleWeatherReport) async throws {
        writtenWeather.removeAll { $0.id == report.id }
        writtenWeather.append(report)
    }

    public func removeWeather(id: UUID) async throws {
        writtenWeather.removeAll { $0.id == id }
    }

    public func writeWeatherLocationOrder(_ orderedIDs: [UUID]) async throws {
        writtenWeatherLocationOrder = orderedIDs
    }

    public func writeWatchSetting(_ setting: WatchSetting, isOn: Bool) async throws {
        writtenWatchSettings[setting] = isOn
    }

    public func writeActivitySettings(_ settings: PebbleActivitySettings) async throws {
        writtenActivitySettings = settings
    }

    public func writeHeartRateSettings(_ settings: PebbleHeartRateSettings) async throws {
        writtenHeartRateSettings = settings
    }

    public func writeHealthDay(_ day: PebbleHealthDay) async throws {
        writtenHealthDays.removeAll { $0.weekday == day.weekday }
        writtenHealthDays.append(day)
    }

    public func writeReminderAppState(_ state: PebbleReminderAppState) async throws {
        writtenReminderAppState = state
    }

    public func registerApplication(_ metadata: PebbleAppMetadata) async throws {
        registeredApplications.removeAll { $0.applicationID == metadata.applicationID }
        registeredApplications.append(metadata)
    }

    public func unregisterApplication(applicationID: UUID) async throws {
        unregisteredApplicationIDs.append(applicationID)
        registeredApplications.removeAll { $0.applicationID == applicationID }
    }
}
