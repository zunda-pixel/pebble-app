public import PebbleProtocol
public import Foundation

@MainActor
public final class MockWatchClient: WatchClient {
    public private(set) var sentFrames: [PebbleProtocolFrame] = []
    public private(set) var sentAppMessages: [AppMessageData] = []
    public private(set) var appMessageResponses: [(transactionID: UInt8, acknowledged: Bool)] = []
    public private(set) var appFetchResponses: [AppFetchResponseStatus] = []
    public private(set) var reorderedApplicationIDs: [[UUID]] = []
    public private(set) var sentNotifications: [PebbleTimelineNotification] = []
    public private(set) var timelinePins: [TimelinePin] = []
    /// Every pin write in the order it was made, including the ones that
    /// replaced a pin already here. `timelinePins` keeps one entry per pin the
    /// way the watch does, so it cannot say how often the same one was sent.
    public private(set) var timelinePinWrites: [UUID] = []
    /// Every pin removal in order, for the same reason: removing a pin that has
    /// already gone leaves no trace in `timelinePins`.
    public private(set) var timelinePinRemovals: [UUID] = []
    public private(set) var clearedTimelineCount = 0
    public private(set) var installedObjects: [(bytes: [UInt8], objectType: PutBytesObjectType, appBankID: UInt32)] = []
    public private(set) var installedFirmwarePackages: [PBZFirmwarePackage] = []
    public private(set) var installedFiles: [(bytes: [UInt8], filename: String)] = []
    public private(set) var writtenWeather: [WeatherReport] = []
    public private(set) var timelineReminders: [TimelinePin] = []
    public private(set) var writtenWeatherLocationOrder: [UUID] = []
    public private(set) var writtenWatchSettings: [WatchSetting: Int] = [:]
    public private(set) var writtenQuickLaunch: [QuickLaunchButton: QuickLaunchAssignment] = [:]
    public private(set) var writtenActivitySettings: ActivitySettings?
    public private(set) var writtenHeartRateSettings: HeartRateSettings?
    public private(set) var writtenHealthDays: [WatchHealthDay] = []
    public private(set) var writtenReminderAppState: PebbleReminderAppState?
    public private(set) var sentImages: [(token: UInt8, kindValue: UInt8, image: EncodedImage?)] = []
    public private(set) var declinedImageKinds: [UInt8] = []
    public private(set) var screenshotRequestCount = 0
    public private(set) var requestedLogGenerations: [UInt8] = []
    public private(set) var isApplicationLoggingEnabled = false
    public private(set) var getBytesRequests: [GetBytesRequest] = []
    /// What a test wants the watch to answer with.
    public var screenshotToReturn = WatchScreenshot(width: 1, height: 1, pixels: [0xFF00_0000])
    public var logGenerations: [[WatchLogLine]] = []
    public var bytesToReturn: [UInt8] = []
    public private(set) var writtenNotificationSourceApps: [NotificationSourceApp] = []
    public private(set) var writtenAppGlances: [AppGlance] = []
    /// Every glance write in order, including the ones that replaced a glance
    /// already here. `writtenAppGlances` keeps one entry per application the way
    /// the watch does, so it cannot say how often the same one was sent.
    public private(set) var appGlanceWrites: [UUID] = []
    public private(set) var deletedTimelineReminderIDs: [UUID] = []
    public private(set) var registeredApplications: [PebbleAppMetadata] = []
    public private(set) var unregisteredApplicationIDs: [UUID] = []
    public private(set) var disconnectedWatches: [ConnectedWatch] = []
    private var nextTransactionID: UInt8 = 0
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<WatchClientEvent>.Continuation?

    public private(set) var startBluetoothCount = 0
    public private(set) var reportedHandshakePhases: [WatchHandshakePhase] = []
    /// Called just after each phase has been reported, so a test can look at
    /// what the app made of it without waiting for the connect to finish.
    public var afterReportingPhase: (@MainActor (WatchHandshakePhase) -> Void)?

    public init() {}

    public func startBluetooth() {
        startBluetoothCount += 1
    }

    public func scan() async throws -> [DiscoveredWatch] {
        try await Task.sleep(for: .milliseconds(400))

        return [
            DiscoveredWatch(
                id: WatchID("mock-flint"),
                name: "Pebble 2 Duo",
                model: .pebble2Duo,
                signalStrength: -42
            ),
            DiscoveredWatch(
                id: WatchID("mock-emery"),
                name: "Pebble Time 2",
                model: .pebbleTime2,
                signalStrength: -57
            ),
            DiscoveredWatch(
                id: WatchID("mock-gabbro"),
                name: "Pebble Round 2",
                model: .pebbleRound2,
                signalStrength: -68
            ),
        ]
    }

    public func retrieveKnownWatches(_ hints: [DiscoveredWatch]) async throws -> [DiscoveredWatch] {
        hints
    }

    /// Makes the next connection report a watch running recovery firmware.
    public var connectsAsRecoveryFirmware = false
    /// Makes connecting fail the way a watch out of range or with an unusable
    /// protocol service does.
    public var connectionFailure: WatchConnectionError?

    /// Reports both handshake phases, so a test can see the states a real
    /// connect passes through rather than only its result.
    public func connect(
        to device: DiscoveredWatch,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        try await Task.sleep(for: .milliseconds(250))
        reportingPhase(.linkOpen)
        reportedHandshakePhases.append(.linkOpen)
        afterReportingPhase?(.linkOpen)
        try await Task.sleep(for: .milliseconds(250))
        if let connectionFailure {
            throw connectionFailure
        }
        reportingPhase(.transportOpen)
        reportedHandshakePhases.append(.transportOpen)
        afterReportingPhase?(.transportOpen)

        return ConnectedWatch(
            id: device.id,
            name: device.name,
            model: device.model,
            batteryLevel: 84,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0-mock",
                serialNumber: "MOCK00000001",
                // The platform this mock's model would report, so the board and
                // the model agree the way they do on a real watch.
                hardwarePlatform: device.model == .pebble2Duo ? 15 : 18,
                isRunningRecoveryFirmware: connectsAsRecoveryFirmware
            )
        )
    }

    public func disconnect(from device: ConnectedWatch) async {
        disconnectedWatches.append(device)
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

    public func events() -> AsyncStream<WatchClientEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {}

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        reorderedApplicationIDs.append(applicationIDs)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        appFetchResponses.append(status)
    }

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

    /// What the watch refuses. Set after connecting — the synchronization a
    /// connect runs writes most of these records — to see what the app makes of
    /// a refusal, which for several of them used to be nothing at all.
    public var writeFailure: (any Error)?
    public var removeFailure: (any Error)?

    /// One switch over every record, filling the same typed lists the tests
    /// have always read. A recorder the app never writes to is a case that was
    /// forgotten, and the compiler says which.
    public func write(_ record: BlobDBRecord) async throws {
        if let writeFailure { throw writeFailure }
        switch record {
        case .application(let metadata):
            registeredApplications.removeAll { $0.applicationID == metadata.applicationID }
            registeredApplications.append(metadata)
        case .notification(let notification):
            sentNotifications.append(notification)
        case .timelinePin(let pin):
            timelinePins.removeAll { $0.id == pin.id }
            timelinePins.append(pin)
            timelinePinWrites.append(pin.id)
        case .timelineReminder(let reminder):
            timelineReminders.removeAll { $0.id == reminder.id }
            timelineReminders.append(reminder)
        case .notificationSourceApp(let app):
            writtenNotificationSourceApps.removeAll { $0.bundleID == app.bundleID }
            writtenNotificationSourceApps.append(app)
        case .appGlance(let glance):
            writtenAppGlances.removeAll { $0.applicationID == glance.applicationID }
            writtenAppGlances.append(glance)
            appGlanceWrites.append(glance.applicationID)
        case .weather(let report):
            writtenWeather.removeAll { $0.id == report.id }
            writtenWeather.append(report)
        case .weatherOrder(let orderedIDs):
            writtenWeatherLocationOrder = orderedIDs
        case .watchSetting(let setting, let rawValue):
            writtenWatchSettings[setting] = rawValue
        case .quickLaunch(let button, let assignment):
            writtenQuickLaunch[button] = assignment
        case .activitySettings(let settings):
            writtenActivitySettings = settings
        case .heartRateSettings(let settings):
            writtenHeartRateSettings = settings
        case .healthDay(let day):
            writtenHealthDays.removeAll { $0.weekday == day.weekday }
            writtenHealthDays.append(day)
        case .reminderAppState(let state):
            writtenReminderAppState = state
        }
    }

    public func remove(_ key: BlobDBKey) async throws {
        if let removeFailure { throw removeFailure }
        switch key {
        case .application(let applicationID):
            unregisteredApplicationIDs.append(applicationID)
            registeredApplications.removeAll { $0.applicationID == applicationID }
        case .timelinePin(let id):
            timelinePins.removeAll { $0.id == id }
            timelinePinRemovals.append(id)
        case .timelineReminder(let id):
            timelineReminders.removeAll { $0.id == id }
            // Kept because a reminder the watch made was never written here, so
            // its absence from `timelineReminders` says nothing on its own.
            deletedTimelineReminderIDs.append(id)
        case .notificationSourceApp(let bundleID):
            writtenNotificationSourceApps.removeAll { $0.bundleID == bundleID }
        case .appGlance(let applicationID):
            writtenAppGlances.removeAll { $0.applicationID == applicationID }
        case .weather(let id):
            writtenWeather.removeAll { $0.id == id }
        case .allTimelinePins:
            clearedTimelineCount += 1
            timelinePins.removeAll()
        }
    }

    public func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        switch request {
        case .screenshot:
            screenshotRequestCount += 1
            return .screenshot(screenshotToReturn)
        case .logGeneration(let generation):
            requestedLogGenerations.append(generation)
            guard Int(generation) < logGenerations.count else { return .logLines(nil) }
            return .logLines(logGenerations[Int(generation)])
        case .file(let fileRequest):
            getBytesRequests.append(fileRequest)
            return .bytes(bytesToReturn)
        }
    }

    public func launchApplication(id: UUID) async throws {
        eventContinuation?.yield(.appRunStateChanged(.started(id)))
    }

    public func emit(_ frame: PebbleProtocolFrame) {
        frameContinuation?.yield(frame)
    }

    public func emit(_ event: WatchClientEvent) {
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

    public func sendImage(token: UInt8, kindValue: UInt8, image: EncodedImage?) async throws {
        sentImages.append((token: token, kindValue: kindValue, image: image))
    }

    public func declineImageKind(token: UInt8, kindValue: UInt8) async throws {
        declinedImageKinds.append(kindValue)
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        isApplicationLoggingEnabled = isEnabled
    }
}
