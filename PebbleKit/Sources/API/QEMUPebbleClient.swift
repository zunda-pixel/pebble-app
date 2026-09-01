#if os(macOS)
public import Foundation
import Network

@MainActor
public final class QEMUPebbleClient: PebbleClient {
    private var host: NWEndpoint.Host
    private var port: NWEndpoint.Port
    private var connection: NWConnection?
    private var receiveBuffer: [UInt8] = []
    private var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<PebbleClientEvent>.Continuation?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var versionContinuation: CheckedContinuation<WatchVersionInformation, any Error>?
    private var operationContinuation: CheckedContinuation<Void, any Error>?
    private var operationTimeoutTask: Task<Void, Never>?
    private var pendingBlobToken: UInt16?
    private var nextBlobToken: UInt16 = 1
    private var expectedBlobStatuses: [BlobDBStatus] = []
    private var waitingForReorder = false
    private var transferSession: PutBytesTransferSession?
    private var completedTransferCookie: UInt32?
    private var waitingForFirmwareStart = false
    /// Set for the whole of `installFirmware`, transfers and all.
    private var isInstallingFirmware = false
    private var pendingInstallCookie: UInt32?
    private var nextAppMessageTransactionID: UInt8 = 0
    private var pendingAppMessageTransactionID: UInt8?
    private var reconnectDevice: DiscoveredPebble?
    private var connectedDevice: PebbleDevice?
    private var reconnectTask: Task<Void, Never>?
    private var isManualDisconnect = false
    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()

    public init(host: String = "127.0.0.1", port: UInt16 = 12_344) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 12_344
    }

    public func scan() async throws -> [DiscoveredPebble] {
        [DiscoveredPebble(
            id: "qemu-emery",
            name: "Pebble QEMU",
            model: .pebbleTime2,
            signalStrength: 0
        )]
    }

    public func connect(to device: DiscoveredPebble) async throws -> PebbleDevice {
        reconnectDevice = device
        isManualDisconnect = false
        return try await establishConnection(to: device)
    }

    private func establishConnection(to device: DiscoveredPebble) async throws -> PebbleDevice {
        guard connection == nil else { throw PebbleConnectionError.connectionAlreadyInProgress }
        // Nothing survives the socket that carried it: half a message and half
        // a frame belong to the link that dropped, and a data-logging session
        // id means only what the emulator said it meant on that link.
        receiveBuffer.removeAll()
        frameDecoder = PebbleProtocolFrameDecoder()
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            openContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleConnectionState(state) }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        receiveNextMessage()
        let information = try await withCheckedThrowingContinuation { continuation in
            versionContinuation = continuation
            Task {
                do {
                    try await send(WatchVersionCodec.requestFrame())
                } catch {
                    finishVersion(throwing: error)
                }
            }
            operationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.finishVersion(throwing: PebbleConnectionError.connectionTimedOut)
            }
        }
        try await synchronizeTime()
        let device = PebbleDevice(
            id: device.id,
            name: device.name,
            model: PebbleWatchModel(hardwarePlatform: information.hardwarePlatform) ?? device.model,
            firmwareVersion: information.firmwareVersion,
            batteryLevel: nil,
            serialNumber: information.serialNumber
        )
        connectedDevice = device
        return device
    }

    public func disconnect(from device: PebbleDevice) async {
        isManualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        connectedDevice = nil
        reconnectDevice = nil
        failOperation(PebbleConnectionError.disconnected)
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        guard let connection else { throw PebbleConnectionError.disconnected }
        await PebbleDiagnostics.shared.recordFrame(direction: "out", frame: frame)
        let frameBytes = try frame.encoded()
        guard frameBytes.count <= 2_048 else { throw QEMUTransportError.messageTooLarge }
        var bytes: [UInt8] = [0xFE, 0xED, 0x00, 0x01]
        bytes.append(UInt8(frameBytes.count >> 8))
        bytes.append(UInt8(frameBytes.count & 0xFF))
        bytes.append(contentsOf: frameBytes)
        bytes.append(contentsOf: [0xBE, 0xEF])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func frames() -> AsyncStream<PebbleProtocolFrame> {
        AsyncStream { continuation in frameContinuation = continuation }
    }

    public func events() -> AsyncStream<PebbleClientEvent> {
        AsyncStream { continuation in eventContinuation = continuation }
    }

    public func synchronizeTime() async throws {
        try await send(TimeSynchronizationCodec.frame())
    }

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        guard operationContinuation == nil else { throw AppReorderClientError.operationAlreadyInProgress }
        waitingForReorder = true
        try await performOperation(frame: AppReorderCodec.frame(applicationIDs: applicationIDs))
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        try await send(AppFetchCodec.responseFrame(status: status))
    }

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard operationContinuation == nil else { throw AppReorderClientError.operationAlreadyInProgress }
        let transactionID = nextAppMessageTransactionID
        nextAppMessageTransactionID &+= 1
        pendingAppMessageTransactionID = transactionID
        try await performOperation(frame: try AppMessageCodec.pushFrame(AppMessageData(
            transactionID: transactionID,
            applicationID: applicationID,
            tuples: tuples
        )), timeout: .seconds(10))
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        try await send(AppMessageCodec.resultFrame(
            transactionID: transactionID,
            acknowledged: acknowledged
        ))
    }

    public func sendNotification(_ notification: PebbleTimelineNotification) async throws {
        try await performBlobOperation { token in
            try TimelineNotificationCodec.insertFrame(notification, token: token)
        }
    }

    public func upsertTimelinePin(_ pin: PebbleTimelinePin) async throws {
        try await performBlobOperation { token in try TimelinePinCodec.insertFrame(pin, token: token) }
    }

    public func deleteTimelinePin(id: UUID) async throws {
        try await performBlobOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            TimelinePinCodec.deleteFrame(id: id, token: token)
        }
    }

    public func launchApplication(id: UUID) async throws {
        try await send(AppRunStateCodec.startFrame(applicationID: id))
    }

    public func writeNotificationSourceApp(_ app: NotificationSourceApp) async throws {
        throw BlobDBClientError.rejected(.notSupported)
    }

    public func removeNotificationSourceApp(bundleID: String) async throws {
        throw BlobDBClientError.rejected(.notSupported)
    }

    public func upsertTimelineReminder(_ reminder: PebbleTimelinePin) async throws {
        try await send(try TimelineReminderCodec.insertFrame(reminder, token: 1))
    }

    public func deleteTimelineReminder(id: UUID) async throws {
        try await send(TimelineReminderCodec.deleteFrame(id: id, token: 1))
    }

    public func writeWeather(_ report: PebbleWeatherReport) async throws {
        throw BlobDBClientError.rejected(.notSupported)
    }

    public func removeWeather(id: UUID) async throws {
        throw BlobDBClientError.rejected(.notSupported)
    }

    public func writeWeatherLocationOrder(_ orderedIDs: [UUID]) async throws {
        throw BlobDBClientError.rejected(.notSupported)
    }

    public func writeWatchSetting(_ setting: WatchSetting, isOn: Bool) async throws {
        try await send(WatchSettingsCodec.insertFrame(setting, isOn: isOn, token: 1))
    }

    public func writeActivitySettings(_ settings: PebbleActivitySettings) async throws {
        try await send(HealthSettingsCodec.insertFrame(settings, token: 1))
    }

    public func writeHeartRateSettings(_ settings: PebbleHeartRateSettings) async throws {
        try await send(HealthSettingsCodec.insertFrame(settings, token: 1))
    }

    public func writeHealthDay(_ day: PebbleHealthDay) async throws {
        try await send(HealthStatsCodec.movementFrame(for: day, token: 1))
        try await send(HealthStatsCodec.sleepFrame(for: day, token: 2))
    }

    public func writeReminderAppState(_ state: PebbleReminderAppState) async throws {
        try await send(WeatherCodec.reminderAppFrame(state: state, token: 1))
    }

    public func sendImage(token: UInt8, kindValue: UInt8, image: PebbleEncodedImage?) async throws {
        for frame in ImagingCodec.responseFrames(token: token, kindValue: kindValue, image: image) {
            try await send(frame)
        }
    }

    public func declineImageKind(token: UInt8, kindValue: UInt8) async throws {
        try await send(ImagingCodec.unsupportedFrame(token: token, kindValue: kindValue))
    }

    // The emulator has no screen to photograph, no flash log and no crash to
    // hand over.
    public func takeScreenshot() async throws -> PebbleScreenshot {
        throw WatchPullError.notSupported
    }

    public func readLogGeneration(_ generation: UInt8) async throws -> [WatchLogLine]? {
        nil
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func getBytes(_ request: GetBytesRequest) async throws -> [UInt8] {
        throw WatchPullError.notSupported
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        // The emulator has no filesystem the app can write into.
        throw PutBytesTransferError.invalidConfiguration
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        completedTransferCookie = nil
        guard operationContinuation == nil else { throw PutBytesClientError.transferAlreadyInProgress }
        var session = PutBytesTransferSession(
            bytes: bytes,
            objectType: objectType,
            appBankID: appBankID
        )
        let first = try session.start()
        transferSession = session
        guard case .send(let frame) = first else { throw PutBytesTransferError.invalidState }
        try await performOperation(frame: frame, timeout: .seconds(20))
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // An install is a sequence of operations with gaps between them, and
        // every step shares the same transfer state and install cookie. A
        // second install slipping into one of those gaps would take both over
        // and leave the first waiting on a reply that is no longer its own.
        guard !isInstallingFirmware else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        isInstallingFirmware = true
        defer { isInstallingFirmware = false }
        let total = package.firmware.count + (package.resources?.count ?? 0)
        guard let byteCount = UInt32(exactly: total) else { throw PutBytesTransferError.invalidConfiguration }
        waitingForFirmwareStart = true
        try await performOperation(frame: SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: byteCount), timeout: .seconds(10))
        try await installApplicationObject([UInt8](package.firmware), objectType: package.manifest.firmware.type == "recovery" ? .recovery : .firmware, appBankID: UInt32(package.manifest.firmware.slot ?? 0))
        guard let firmwareCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
        var cookies = [firmwareCookie]
        if let resources = package.resources {
            try await installApplicationObject([UInt8](resources), objectType: .systemResource, appBankID: 0)
            guard let resourceCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
            cookies.append(resourceCookie)
        }
        for cookie in cookies {
            pendingInstallCookie = cookie
            try await performOperation(frame: PutBytesCodec.installFrame(cookie: cookie), timeout: .seconds(10))
        }
        try await send(SystemMessageCodec.firmwareUpdateCompleteFrame())
    }

    public func registerApplication(_ metadata: PebbleAppMetadata) async throws {
        try await performBlobOperation { token in
            BlobDBCodec.insertApplicationFrame(metadata: metadata, token: token)
        }
    }

    public func unregisterApplication(applicationID: UUID) async throws {
        try await performBlobOperation(acceptedStatuses: [.success, .keyDoesNotExist]) { token in
            BlobDBCodec.deleteApplicationFrame(applicationID: applicationID, token: token)
        }
    }

    private func performBlobOperation(
        acceptedStatuses: [BlobDBStatus] = [.success],
        frame: (UInt16) throws -> PebbleProtocolFrame
    ) async throws {
        guard operationContinuation == nil else { throw BlobDBClientError.operationAlreadyInProgress }
        let token = nextBlobToken
        nextBlobToken &+= 1
        pendingBlobToken = token
        expectedBlobStatuses = acceptedStatuses
        try await performOperation(frame: try frame(token))
    }

    private func performOperation(
        frame: PebbleProtocolFrame,
        timeout: Duration = .seconds(20)
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            operationContinuation = continuation
            Task {
                do { try await send(frame) } catch { failOperation(error) }
            }
            operationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.failOperation(PebbleConnectionError.connectionTimedOut)
            }
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            openContinuation?.resume()
            openContinuation = nil
        case .failed(let error):
            let shouldReconnect = (connectedDevice != nil || reconnectTask != nil) && !isManualDisconnect
            openContinuation?.resume(throwing: error)
            openContinuation = nil
            finishVersion(throwing: error)
            failOperation(error)
            connection = nil
            connectedDevice = nil
            if shouldReconnect {
                scheduleReconnect()
            } else {
                eventContinuation?.yield(.disconnected(.disconnected))
            }
        case .cancelled:
            openContinuation?.resume(throwing: PebbleConnectionError.disconnected)
            openContinuation = nil
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let reconnectDevice else { return }
        eventContinuation?.yield(.reconnecting(deviceID: reconnectDevice.id))
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for delay in [1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, !self.isManualDisconnect else { return }
                do {
                    let device = try await self.establishConnection(to: reconnectDevice)
                    self.reconnectTask = nil
                    self.eventContinuation?.yield(.deviceUpdated(device))
                    return
                } catch {
                    self.connection?.cancel()
                    self.connection = nil
                }
            }
            self.reconnectTask = nil
            self.eventContinuation?.yield(.disconnected(.connectionFailed))
        }
    }

    private func receiveNextMessage() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.consume([UInt8](data)) }
                if let error {
                    self.handleConnectionState(.failed(error))
                } else if complete {
                    self.handleConnectionState(.failed(NWError.posix(.ECONNRESET)))
                } else {
                    self.receiveNextMessage()
                }
            }
        }
    }

    private func consume(_ bytes: [UInt8]) {
        receiveBuffer.append(contentsOf: bytes)
        while receiveBuffer.count >= 8 {
            guard let signature = receiveBuffer.indices.dropLast().first(where: {
                receiveBuffer[$0] == 0xFE && receiveBuffer[$0 + 1] == 0xED
            }) else {
                receiveBuffer.removeAll(keepingCapacity: true)
                return
            }
            if signature > 0 { receiveBuffer.removeFirst(signature) }
            guard receiveBuffer.count >= 8 else { return }
            let protocolID = UInt16(receiveBuffer[2]) << 8 | UInt16(receiveBuffer[3])
            let length = Int(receiveBuffer[4]) << 8 | Int(receiveBuffer[5])
            guard length <= 2_048 else {
                receiveBuffer.removeFirst(2)
                continue
            }
            let packetLength = 6 + length + 2
            guard receiveBuffer.count >= packetLength else { return }
            guard receiveBuffer[packetLength - 2] == 0xBE,
                  receiveBuffer[packetLength - 1] == 0xEF else {
                receiveBuffer.removeFirst(2)
                continue
            }
            let payload = Array(receiveBuffer[6..<(6 + length)])
            receiveBuffer.removeFirst(packetLength)
            if protocolID == 1 { consumePebbleProtocol(payload) }
        }
    }

    private func consumePebbleProtocol(_ bytes: [UInt8]) {
        // Every frame in the chunk gets its own attempt: one unusable frame
        // must not swallow the reply an operation is waiting for, which may
        // well have arrived in the same read.
        let batch = frameDecoder.append(bytes)
        var firstFailure: (any Error)?
        if let failure = batch.failure {
            firstFailure = failure
        }
        for frame in batch.frames {
            do {
                try process(frame)
            } catch {
                if firstFailure == nil {
                    firstFailure = error
                }
            }
            frameContinuation?.yield(frame)
        }
        if let firstFailure {
            failOperation(firstFailure)
        }
    }

    private func process(_ frame: PebbleProtocolFrame) throws {
        Task { await PebbleDiagnostics.shared.recordFrame(direction: "in", frame: frame) }
        if frame.endpoint == WatchVersionCodec.endpoint, versionContinuation != nil {
            finishVersion(returning: try WatchVersionCodec.decode(frame))
        } else if frame.endpoint == PingPongCodec.endpoint {
            if case .ping(let cookie) = try PingPongCodec.decode(frame) {
                Task { try? await send(PingPongCodec.frame(for: .pong(cookie: cookie))) }
            }
        } else if PhoneVersionCodec.isRequest(frame) {
            Task { try? await send(PhoneVersionCodec.responseFrame(operatingSystem: .macOS)) }
        } else if frame.endpoint == AppFetchCodec.endpoint {
            eventContinuation?.yield(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))
        } else if frame.endpoint == HealthSyncCodec.endpoint {
            eventContinuation?.yield(.healthSyncCompleted(try HealthSyncResponseCodec.decode(frame)))
        } else if frame.endpoint == HealthDataLoggingCodec.endpoint {
            let result = try healthDataLoggingProcessor.process(frame)
            if let response = result.response { Task { try? await send(response) } }
            if !result.samples.isEmpty { eventContinuation?.yield(.healthSamplesReceived(result.samples)) }
        } else if frame.endpoint == TimelineActionCodec.endpoint {
            let invocation = try TimelineActionCodec.decode(frame)
            eventContinuation?.yield(.timelineActionInvoked(invocation))
            Task { try? await send(TimelineActionCodec.responseFrame(itemID: invocation.itemID, succeeded: true)) }
        } else if frame.endpoint == ImagingCodec.endpoint {
            eventContinuation?.yield(.imageRequested(try ImagingCodec.decode(frame)))
        } else if frame.endpoint == AppRunStateCodec.endpoint {
            eventContinuation?.yield(.appRunStateChanged(try AppRunStateCodec.decode(frame)))
        } else if frame.endpoint == BlobDBCodec.endpoint, let token = pendingBlobToken {
            let response = try BlobDBCodec.decodeResponse(frame)
            guard response.token == token else { return }
            guard expectedBlobStatuses.contains(response.status) else {
                failOperation(BlobDBClientError.rejected(response.status))
                return
            }
            pendingBlobToken = nil
            expectedBlobStatuses = []
            finishOperation()
        } else if frame.endpoint == AppReorderCodec.endpoint, waitingForReorder {
            let result = try AppReorderCodec.decodeResult(frame)
            waitingForReorder = false
            result == .success ? finishOperation() : failOperation(AppReorderClientError.rejected(result))
        } else if frame.endpoint == PutBytesCodec.endpoint, var session = transferSession {
            let actions = try session.receive(try PutBytesCodec.decodeResponse(frame))
            transferSession = session
            for action in actions {
                switch action {
                case .send(let nextFrame): Task { try? await send(nextFrame) }
                case .progress(let progress): eventContinuation?.yield(.transferProgress(progress))
                case .finished:
                    completedTransferCookie = session.completedCookie
                    transferSession = nil
                    finishOperation()
                }
            }
        } else if frame.endpoint == PutBytesCodec.endpoint, let cookie = pendingInstallCookie {
            let response = try PutBytesCodec.decodeResponse(frame)
            guard response.cookie == cookie else { return }
            pendingInstallCookie = nil
            response.result == .acknowledgement ? finishOperation() : failOperation(PutBytesTransferError.negativeAcknowledgement)
        } else if frame.endpoint == SystemMessageCodec.endpoint, waitingForFirmwareStart {
            waitingForFirmwareStart = false
            try SystemMessageCodec.decodeFirmwareUpdateStartResponse(frame)
                ? finishOperation()
                : failOperation(SystemMessageCodecError.updateRejected)
        } else if frame.endpoint == AppMessageCodec.endpoint {
            switch try AppMessageCodec.decode(frame) {
            case .push(let message): eventContinuation?.yield(.appMessageReceived(message))
            case .acknowledgement(let transactionID) where transactionID == pendingAppMessageTransactionID:
                pendingAppMessageTransactionID = nil
                finishOperation()
            case .negativeAcknowledgement(let transactionID) where transactionID == pendingAppMessageTransactionID:
                pendingAppMessageTransactionID = nil
                failOperation(AppMessageClientError.negativeAcknowledgement)
            default: break
            }
        }
    }

    private func finishVersion(returning information: WatchVersionInformation? = nil, throwing error: (any Error)? = nil) {
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        if let error { versionContinuation?.resume(throwing: error) }
        else if let information { versionContinuation?.resume(returning: information) }
        versionContinuation = nil
    }

    private func finishOperation() {
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        operationContinuation?.resume()
        operationContinuation = nil
    }

    private func failOperation(_ error: any Error) {
        operationTimeoutTask?.cancel()
        operationTimeoutTask = nil
        pendingBlobToken = nil
        expectedBlobStatuses = []
        waitingForReorder = false
        transferSession = nil
        pendingAppMessageTransactionID = nil
        pendingInstallCookie = nil
        waitingForFirmwareStart = false
        operationContinuation?.resume(throwing: error)
        operationContinuation = nil
        // The version handshake shares this one timeout task, so abandoning an
        // operation abandons the handshake's only deadline. Anything that gives
        // up on an operation has given up on the handshake too, and `connect`
        // is sitting on the other end of it.
        finishVersion(throwing: error)
    }
}

public enum QEMUTransportError: Error, Equatable, Sendable {
    case messageTooLarge
}
#endif
