import API
import Foundation

/// A watch that takes a moment to answer.
///
/// `MockPebbleClient` returns from every call without ever suspending, so two
/// pieces of work that read the same queue can never interleave in a test the
/// way they do against a real watch. This one suspends inside the calls the
/// queues use, and can be told to refuse them, which is what makes the races
/// and the rollbacks observable.
@MainActor
final class SuspendingPebbleClient: PebbleClient {
    /// How long each answer takes. Long enough for a second task to reach the
    /// same queue, short enough not to slow the suite down.
    var answerDelay: Duration = .milliseconds(20)
    /// What the watch refuses, if anything.
    var notificationFailure: (any Error)?
    var appMessageFailure: (any Error)?
    var transferFailure: (any Error)?

    private(set) var sentNotifications: [PebbleTimelineNotification] = []
    private(set) var sentAppMessages: [(applicationID: UUID, tuples: [AppMessageTuple])] = []
    private(set) var installedObjects: [(objectType: PutBytesObjectType, appBankID: UInt32)] = []
    private(set) var appFetchResponses: [AppFetchResponseStatus] = []
    private(set) var upsertedPins: [PebbleTimelinePin] = []
    private(set) var deletedPinIDs: [UUID] = []
    private(set) var sentFrames: [PebbleProtocolFrame] = []
    private(set) var disconnectedDevices: [PebbleDevice] = []
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?

    init() {}

    private func answer() async {
        try? await Task.sleep(for: answerDelay)
    }

    func scan() async throws -> [DiscoveredPebble] {
        [DiscoveredPebble(id: "suspending-emery", name: "Pebble Time 2", model: .pebbleTime2, signalStrength: -50)]
    }

    func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        PebbleDevice(
            id: device.id,
            name: device.name,
            model: device.model,
            firmwareVersion: "v5.0.0-test",
            batteryLevel: 70,
            serialNumber: "TEST00000001"
        )
    }

    func disconnect(from device: PebbleDevice) async {
        disconnectedDevices.append(device)
    }

    func send(_ frame: PebbleProtocolFrame) async throws {
        sentFrames.append(frame)
    }

    func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { frameContinuation = $0 }
    }

    func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { eventContinuation = $0 }
    }

    func emit(_ event: PebbleClientEvent) {
        eventContinuation?.yield(event)
    }

    func sendNotification(_ notification: PebbleTimelineNotification) async throws {
        await answer()
        if let notificationFailure { throw notificationFailure }
        sentNotifications.append(notification)
    }

    func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        await answer()
        if let appMessageFailure { throw appMessageFailure }
        sentAppMessages.append((applicationID, tuples))
    }

    func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        await answer()
        if let transferFailure { throw transferFailure }
        installedObjects.append((objectType, appBankID))
    }

    func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        appFetchResponses.append(status)
    }

    func upsertTimelinePin(_ pin: PebbleTimelinePin) async throws {
        upsertedPins.removeAll { $0.id == pin.id }
        upsertedPins.append(pin)
    }

    func deleteTimelinePin(id: UUID) async throws {
        upsertedPins.removeAll { $0.id == id }
        deletedPinIDs.append(id)
    }

    // Everything below is not what these tests are about: the watch takes it
    // and says nothing.
    func synchronizeTime() async throws {}
    func reorderApplications(_ applicationIDs: [UUID]) async throws {}
    func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {}
    func upsertTimelineReminder(_ reminder: PebbleTimelinePin) async throws {}
    func deleteTimelineReminder(id: UUID) async throws {}
    func launchApplication(id: UUID) async throws {}
    func installFirmware(_ package: PBZFirmwarePackage) async throws {}
    func installFile(_ bytes: [UInt8], filename: String) async throws {}
    func writeNotificationSourceApp(_ app: NotificationSourceApp) async throws {}
    func removeNotificationSourceApp(bundleID: String) async throws {}
    func writeWeather(_ report: PebbleWeatherReport) async throws {}
    func removeWeather(id: UUID) async throws {}
    func writeWeatherLocationOrder(_ orderedIDs: [UUID]) async throws {}
    func writeWatchSetting(_ setting: WatchSetting, isOn: Bool) async throws {}
    func writeActivitySettings(_ settings: PebbleActivitySettings) async throws {}
    func writeHeartRateSettings(_ settings: PebbleHeartRateSettings) async throws {}
    func writeHealthDay(_ day: PebbleHealthDay) async throws {}
    func writeReminderAppState(_ state: PebbleReminderAppState) async throws {}
    func sendImage(token: UInt8, kindValue: UInt8, image: PebbleEncodedImage?) async throws {}
    func declineImageKind(token: UInt8, kindValue: UInt8) async throws {}
    func takeScreenshot() async throws -> PebbleScreenshot { throw WatchPullError.notSupported }
    func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? { nil }
    func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {}
    func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] { [] }
    func registerApplication(_ metadata: PebbleAppMetadata) async throws {}
    func unregisterApplication(applicationID: UUID) async throws {}
}
