import PebbleProtocol
import PebbleTransport
import Foundation

/// A watch that takes a moment to answer.
///
/// `MockWatchClient` returns from every call without ever suspending, so two
/// pieces of work that read the same queue can never interleave in a test the
/// way they do against a real watch. This one suspends inside the calls the
/// queues use, and can be told to refuse them, which is what makes the races
/// and the rollbacks observable.
@MainActor
final class SuspendingWatchClient: WatchClient {
    /// How long each answer takes. Long enough for a second task to reach the
    /// same queue, short enough not to slow the suite down.
    var answerDelay: Duration = .milliseconds(20)
    /// What the watch refuses, if anything.
    var notificationFailure: (any Error)?
    var appMessageFailure: (any Error)?
    var transferFailure: (any Error)?
    /// Refuses timeline-pin writes once this many are held, the way a link
    /// that dies part-way through a synchronization does. Nil takes them all.
    var timelinePinWritesAllowed: Int?
    /// How long a settings write takes, apart from the rest: a watch slow to
    /// take one of those is what holds up the answer to another watch.
    var watchSettingWriteDelay: Duration = .zero

    private(set) var sentNotifications: [TimelineNotification] = []
    private(set) var sentAppMessages: [(applicationID: UUID, tuples: [AppMessageTuple])] = []
    private(set) var installedObjects: [(objectType: PutBytesObjectType, appBankID: UInt32)] = []
    private(set) var appFetchResponses: [AppFetchResponseStatus] = []
    private(set) var upsertedPins: [TimelinePin] = []
    /// Every accepted pin write in order, duplicates included — `upsertedPins`
    /// keeps one entry per pin, which hides a pin written twice.
    private(set) var timelinePinWrites: [UUID] = []
    private(set) var deletedPinIDs: [UUID] = []
    private(set) var writtenWatchSettings: [WatchSetting: Int] = [:]
    private(set) var clearedTimelineCount = 0
    private(set) var sentFrames: [PebbleProtocolFrame] = []
    private(set) var disconnectedWatches: [ConnectedWatch] = []
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<WatchClientEvent>.Continuation?

    init() {}

    private func answer() async {
        try? await Task.sleep(for: answerDelay)
    }

    func scan() async throws -> [DiscoveredWatch] {
        [DiscoveredWatch(id: WatchID("suspending-emery"), name: "Pebble Time 2", model: .pebbleTime2, signalStrength: -50)]
    }

    /// No phases: these tests are about the queues, and a connect that reports
    /// nothing between the link and the answer is what the protocol allows.
    func connect(
        to watch: WatchConnectionTarget,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        ConnectedWatch(
            id: watch.id,
            name: watch.name,
            model: watch.model,
            batteryLevel: 70,
            version: WatchVersionInformation(
                firmwareVersion: "v5.0.0-test",
                serialNumber: "TEST00000001",
                hardwarePlatform: 18
            )
        )
    }

    func disconnect(from watch: ConnectedWatch) async {
        disconnectedWatches.append(watch)
        firmwareTransferHeldByTheLink?.resume(throwing: WatchConnectionError.disconnected)
        firmwareTransferHeldByTheLink = nil
    }

    func send(_ frame: PebbleProtocolFrame) async throws {
        sentFrames.append(frame)
    }

    func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in frameContinuation = continuation }
    }

    func events() -> AsyncStream<WatchClientEvent> {
        AsyncStream { continuation in eventContinuation = continuation }
    }

    func emit(_ event: WatchClientEvent) {
        eventContinuation?.yield(event)
    }

    func emit(_ frame: PebbleProtocolFrame) {
        frameContinuation?.yield(frame)
    }

    func write(_ record: BlobDBRecord) async throws {
        switch record {
        case .notification(let notification):
            await answer()
            if let notificationFailure { throw notificationFailure }
            sentNotifications.append(notification)
        case .timelinePin(let pin):
            if let allowed = timelinePinWritesAllowed, upsertedPins.count >= allowed {
                throw WatchConnectionError.disconnected
            }
            timelinePinWrites.append(pin.id)
            upsertedPins.removeAll { $0.id == pin.id }
            upsertedPins.append(pin)
        case .watchSetting(let setting, let rawValue):
            try? await Task.sleep(for: watchSettingWriteDelay)
            writtenWatchSettings[setting] = rawValue
        // Not what these tests are about: the watch takes it and says nothing.
        default:
            break
        }
    }

    func remove(_ key: BlobDBKey) async throws {
        switch key {
        case .timelinePin(let id):
            upsertedPins.removeAll { $0.id == id }
            deletedPinIDs.append(id)
        case .allTimelinePins:
            await answer()
            upsertedPins.removeAll()
            clearedTimelineCount += 1
        default:
            break
        }
    }

    func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        throw WatchPullError.notSupported
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

    // Everything below is not what these tests are about: the watch takes it
    // and says nothing.
    func synchronizeTime() async throws {}
    func reorderApplications(_ applicationIDs: [UUID]) async throws {}
    func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {}
    func launchApplication(id: UUID) async throws {}
    /// How long each firmware transfer takes, one entry per transfer in the
    /// order they start; once they run out a transfer is instant. Each runs to
    /// the end whatever happens to the task that asked, the way bytes already
    /// on the radio do, and only then reports the cancellation.
    var firmwareTransferTimes: [Duration] = []
    /// Set, the next transfer ignores cancellation and ends only when the link
    /// does, as a real session's waits for the watch's answers do.
    var nextFirmwareTransferEndsWithTheLink = false
    private var firmwareTransferHeldByTheLink: CheckedContinuation<Void, any Error>?

    func installFirmware(_ package: PBZFirmwarePackage) async throws {
        if nextFirmwareTransferEndsWithTheLink {
            nextFirmwareTransferEndsWithTheLink = false
            try await withCheckedThrowingContinuation { firmwareTransferHeldByTheLink = $0 }
            return
        }
        guard !firmwareTransferTimes.isEmpty else { return }
        let time = firmwareTransferTimes.removeFirst()
        await Task { try? await Task.sleep(for: time) }.value
        try Task.checkCancellation()
    }
    func installFile(_ bytes: [UInt8], filename: String) async throws {}
    func sendImage(token: UInt8, kindValue: UInt8, image: EncodedImage?) async throws {}
    func declineImageKind(token: UInt8, kindValue: UInt8) async throws {}
    func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {}
}
