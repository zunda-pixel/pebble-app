#if os(macOS)
public import PebbleProtocol
public import Foundation
import Network

@MainActor
public final class QEMUWatchClient: WatchClient {
    private var host: NWEndpoint.Host
    private var port: NWEndpoint.Port
    private var connection: NWConnection?
    /// Which connection a callback belongs to. `NWConnection` goes on calling
    /// its handlers after `cancel()`, and the `.cancelled` of the link that just
    /// dropped would otherwise resolve the handshake of the one replacing it.
    private var connectionGeneration = 0
    private var receiveBuffer: [UInt8] = []
    private var frameDecoder = PebbleProtocolFrameDecoder()
    private var frameContinuation: AsyncStream<PebbleProtocolFrame>.Continuation?
    private var eventContinuation: AsyncStream<WatchClientEvent>.Continuation?
    private var openContinuation: CheckedContinuation<Void, any Error>?
    // One reply per endpoint, and a queue in front of each that takes turns,
    // as on the Bluetooth transport. A single shared continuation made a
    // BlobDB write, an app message, a reorder and a transfer refuse one
    // another, when they are unrelated features that only need to wait.
    private let versionReply = PendingReply<WatchVersionInformation>()
    private let blobDBReply = PendingReply<Void>()
    private let blobDBQueue = BlobDBQueue()
    private var pendingBlobToken: UInt16?
    private var nextBlobToken: UInt16 = 1
    private var expectedBlobStatuses: [BlobDBStatus] = []
    private let appReorderReply = PendingReply<Void>()
    private let transferReply = PendingReply<UInt32>()
    private let transferQueue = BlobDBQueue()
    private var transferSession: PutBytesTransferSession?
    private var transferCookie: UInt32?
    private let firmwareReply = PendingReply<Void>()
    private var waitingForFirmwareStart = false
    private var isInstallingFirmware = false
    private var pendingInstallCookie: UInt32?
    private let appMessages = AppMessageQueue()
    private var reconnectWatch: WatchConnectionTarget?
    private var connectedWatch: ConnectedWatch?
    private var reconnectTask: Task<Void, Never>?
    private var isManualDisconnect = false
    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()

    public init(host: String = "127.0.0.1", port: UInt16 = 12_344) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 12_344
        appMessages.send = { [weak self] data in
            guard let self else { throw WatchConnectionError.disconnected }
            try write(AppMessageCodec.pushFrame(data))
        }
    }

    public func scan() async throws -> [DiscoveredWatch] {
        [DiscoveredWatch(
            id: WatchID("qemu-emery"),
            name: "Pebble QEMU",
            model: .pebbleTime2,
            signalStrength: nil
        )]
    }

    public func connect(
        to watch: WatchConnectionTarget,
        reportingPhase: @escaping @MainActor (WatchHandshakePhase) -> Void
    ) async throws -> ConnectedWatch {
        reconnectWatch = watch
        isManualDisconnect = false
        return try await establishConnection(to: watch, reportingPhase: reportingPhase)
    }

    private func establishConnection(
        to watch: WatchConnectionTarget,
        reportingPhase: @MainActor (WatchHandshakePhase) -> Void = { _ in }
    ) async throws -> ConnectedWatch {
        guard connection == nil else { throw WatchConnectionError.connectionAlreadyInProgress }
        // Half a message and half a frame belong to the link that dropped, and a
        // data-logging session id means only what the emulator said on that link.
        receiveBuffer.removeAll()
        frameDecoder = PebbleProtocolFrameDecoder()
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
        let connection = NWConnection(host: host, port: port, using: .tcp)
        self.connection = connection
        connectionGeneration += 1
        let generation = connectionGeneration
        // Everything below can throw over a socket that stays healthy — the
        // emulator answers TCP and then says nothing — and nothing else tears
        // that socket down: `disconnect(from:)` needs the watch this never
        // produced. Without the catch, every connect after a timeout answered
        // "already in progress" until the app was relaunched.
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                openContinuation = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in self?.handleConnectionState(state, from: generation) }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
            receiveNextMessage(from: generation)
            // The socket is the link and the transport at once here: there is no
            // service discovery and no PPoG handshake, so both phases land
            // together and the emulator's connect looks instantaneous.
            reportingPhase(.linkOpen)
            reportingPhase(.transportOpen)
            let information = try await versionReply.wait(timeout: .seconds(10)) {
                try write(WatchVersionCodec.requestFrame())
            }
            // Said out loud, as the Bluetooth transport does. It said nothing here,
            // which is how a watch arriving with no board and no capabilities went
            // unremarked in the one environment this project verifies in.
            await DiagnosticLog.shared.record(
                information.isRunningRecoveryFirmware ? .error : .info,
                category: "connection",
                message: "[qemu] \(information.diagnosticSummary)"
                    + (information.isRunningRecoveryFirmware
                        ? " (recovery firmware: only a firmware install will work)"
                        : "")
            )
            // Said without being asked. The emulator opens its session at boot
            // and asks for the phone's version then (`comm_session_open`,
            // `services/comm_session/session.c`), before anything is listening,
            // so it never asks again; until told otherwise it runs on the fixed
            // capabilities `qemu_transport_set_connected` gives it, which lack
            // the weather and settings-sync bits. `session_remote_version.c`
            // takes a response whether or not it asked for one.
            try await send(PhoneVersionCodec.responseFrame(operatingSystem: .macOS))
            try await synchronizeTime()
            let watch = ConnectedWatch(
                id: watch.id,
                name: watch.name,
                model: WatchModel(hardwarePlatform: information.hardwarePlatform) ?? watch.model,
                batteryLevel: nil,
                // One value, so this transport cannot arrive with half of what the
                // watch said — which is exactly what it used to do.
                version: information
            )
            connectedWatch = watch
            appMessages.startNextIfPossible()
            return watch
        } catch {
            discardConnection()
            failWorkInFlight(error)
            throw error
        }
    }

    public func disconnect(from watch: ConnectedWatch) async {
        isManualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        discardConnection()
        connectedWatch = nil
        reconnectWatch = nil
        failWorkInFlight(WatchConnectionError.disconnected)
    }

    /// The emulator's framing around one Pebble Protocol frame: protocol 1 is
    /// the protocol itself, and the length is the frame's.
    private static func packet(for frame: PebbleProtocolFrame) throws -> [UInt8] {
        let frameBytes = try frame.encoded()
        guard frameBytes.count <= 2_048 else { throw QEMUTransportError.messageTooLarge }
        var bytes: [UInt8] = [0xFE, 0xED, 0x00, 0x01]
        bytes.append(UInt8(frameBytes.count >> 8))
        bytes.append(UInt8(frameBytes.count & 0xFF))
        bytes.append(contentsOf: frameBytes)
        bytes.append(contentsOf: [0xBE, 0xEF])
        return bytes
    }

    /// Puts a frame on the socket without waiting for it to leave, for a reply
    /// whose request has to go out while its continuation is being stored. A
    /// socket that cannot take it has failed, and is handled as one.
    private func write(_ frame: PebbleProtocolFrame) throws {
        guard let connection else { throw WatchConnectionError.disconnected }
        let bytes = try Self.packet(for: frame)
        Task { await DiagnosticLog.shared.recordFrame(direction: "out", frame: frame) }
        let generation = connectionGeneration
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.handleConnectionState(.failed(error), from: generation) }
        })
    }

    public func send(_ frame: PebbleProtocolFrame) async throws {
        guard let connection else { throw WatchConnectionError.disconnected }
        await DiagnosticLog.shared.recordFrame(direction: "out", frame: frame)
        let bytes = try Self.packet(for: frame)
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
        AsyncStream { continuation in
            frameContinuation?.finish()
            frameContinuation = continuation
        }
    }

    public func events() -> AsyncStream<WatchClientEvent> {
        AsyncStream { continuation in
            eventContinuation?.finish()
            eventContinuation = continuation
        }
    }

    public func synchronizeTime() async throws {
        try await send(TimeSynchronizationCodec.frame())
    }

    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        guard connection != nil else { throw WatchConnectionError.disconnected }
        guard !appReorderReply.isWaiting else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await appReorderReply.wait(timeout: .seconds(20)) {
            try write(AppReorderCodec.frame(applicationIDs: applicationIDs))
        }
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        try await send(AppFetchCodec.responseFrame(status: status))
    }

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        guard connection != nil else { throw WatchConnectionError.disconnected }
        try await appMessages.enqueue(applicationID: applicationID, tuples: tuples)
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        try await send(AppMessageCodec.resultFrame(
            transactionID: transactionID,
            acknowledged: acknowledged
        ))
    }

    public func write(_ record: BlobDBRecord) async throws {
        for write in record.writes {
            try await performBlobOperation(write)
        }
    }

    public func remove(_ key: BlobDBKey) async throws {
        for write in key.writes {
            try await performBlobOperation(write)
        }
    }

    public func launchApplication(id: UUID) async throws {
        try await send(AppRunStateCodec.startFrame(applicationID: id))
    }

    public func sendImage(token: UInt8, kindValue: UInt8, image: EncodedImage?) async throws {
        for frame in ImagingCodec.responseFrames(token: token, kindValue: kindValue, image: image) {
            try await send(frame)
        }
    }

    public func declineImageKind(token: UInt8, kindValue: UInt8) async throws {
        try await send(ImagingCodec.unsupportedFrame(token: token, kindValue: kindValue))
    }

    /// None of the three: the collectors that read a pull's pieces live with the
    /// Bluetooth client, and the emulator's socket has never carried one.
    /// `readLogGeneration` used to answer nil here, which reads as "the watch
    /// does not go back that far" rather than "this transport cannot ask".
    public func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        throw WatchPullError.notSupported
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        throw PutBytesTransferError.invalidConfiguration
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await transferObject(bytes, objectType: objectType, appBankID: appBankID)
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // Every step of an install shares the same transfer state and install cookie,
        // and there are gaps between them for a second install to slip into.
        guard !isInstallingFirmware else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        isInstallingFirmware = true
        defer { isInstallingFirmware = false }
        // One turn for the whole update rather than one per transfer: an app
        // transfer let in between the firmware and its resources would run on
        // a watch in the middle of replacing its firmware.
        try await transferQueue.begin()
        defer { transferQueue.finish() }
        let total = package.firmware.count + (package.resources?.count ?? 0)
        guard let byteCount = UInt32(exactly: total) else { throw PutBytesTransferError.invalidConfiguration }
        try await sendFirmwareControl(
            SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: byteCount),
            waitingForStart: true
        )
        // Bank 0, the way the Bluetooth transport and the official app send
        // it: `put_bytes.c` uses the index only to name app and resource bank
        // files, and `ObjectFirmware` writes to the scratch region whatever is
        // here. The slot chooses which manifest entry to send, never a bank —
        // and a slot number past MAX_APP_BANKS would be refused outright.
        let firmwareCookie = try await transferObjectHoldingTheTurn(
            [UInt8](package.firmware),
            objectType: package.manifest.firmware.objectType,
            appBankID: 0
        )
        var cookies = [firmwareCookie]
        if let resources = package.resources {
            cookies.append(try await transferObjectHoldingTheTurn(
                [UInt8](resources),
                objectType: .systemResource,
                appBankID: 0
            ))
        }
        for cookie in cookies {
            pendingInstallCookie = cookie
            try await sendFirmwareControl(PutBytesCodec.installFrame(cookie: cookie), waitingForStart: false)
        }
        try await send(SystemMessageCodec.firmwareUpdateCompleteFrame())
    }

    /// Takes its turn behind any transfer already in flight: the emulator,
    /// like the watch, runs one put-bytes transfer at a time.
    @discardableResult
    private func transferObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws -> UInt32 {
        try await transferQueue.begin()
        defer { transferQueue.finish() }
        return try await transferObjectHoldingTheTurn(bytes, objectType: objectType, appBankID: appBankID)
    }

    /// For a caller already holding `transferQueue`'s turn.
    private func transferObjectHoldingTheTurn(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws -> UInt32 {
        guard connection != nil else { throw WatchConnectionError.disconnected }
        guard transferSession == nil else { throw PutBytesClientError.transferAlreadyInProgress }
        var session = PutBytesTransferSession(
            bytes: bytes,
            objectType: objectType,
            appBankID: appBankID
        )
        let first = try session.start()
        transferSession = session
        do {
            return try await transferReply.wait(timeout: .seconds(20)) {
                try handleTransferActions([first])
            }
        } catch {
            abandonTransfer()
            throw error
        }
    }

    /// Clears a transfer whose reply settled without passing through
    /// `.finished` or `failTransfer`: the deadline, or a chunk that could not
    /// be sent. The watch would otherwise hold it open until `PUT_TIMEOUT_MS`
    /// (`services/put_bytes/put_bytes.c`) and refuse the next init meanwhile.
    private func abandonTransfer() {
        guard transferSession != nil, !transferReply.isWaiting else { return }
        if let transferCookie {
            try? write(PutBytesCodec.abortFrame(cookie: transferCookie))
        }
        transferSession = nil
        transferCookie = nil
    }

    private func handleTransferActions(_ actions: [PutBytesTransferAction]) throws {
        for action in actions {
            switch action {
            case .send(let frame):
                try write(frame)
            case .progress(let progress):
                eventContinuation?.yield(.transferProgress(progress))
            case .finished:
                let cookie = transferSession?.completedCookie
                transferSession = nil
                transferCookie = nil
                if let cookie {
                    transferReply.finish(cookie)
                } else {
                    transferReply.fail(PutBytesTransferError.invalidState)
                }
            }
        }
    }

    private func processPutBytesResponse(_ frame: PebbleProtocolFrame) throws {
        guard var session = transferSession else { return }
        let response = try PutBytesCodec.decodeResponse(frame)
        do {
            let actions = try session.receive(response)
            transferSession = session
            transferCookie = response.cookie
            try handleTransferActions(actions)
            // Each acknowledged chunk puts the deadline back: only silence
            // means a transfer has stopped.
            if transferSession != nil {
                transferReply.extendDeadline(.seconds(20))
            }
        } catch {
            try? write(PutBytesCodec.abortFrame(cookie: response.cookie))
            failTransfer(error)
        }
    }

    private func failTransfer(_ error: any Error) {
        transferSession = nil
        transferCookie = nil
        transferReply.fail(error)
    }

    private func sendFirmwareControl(_ frame: PebbleProtocolFrame, waitingForStart: Bool) async throws {
        guard connection != nil else { throw WatchConnectionError.disconnected }
        guard !firmwareReply.isWaiting else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        waitingForFirmwareStart = waitingForStart
        do {
            try await firmwareReply.wait(timeout: .seconds(10)) {
                try write(frame)
            }
        } catch {
            if !firmwareReply.isWaiting {
                waitingForFirmwareStart = false
                pendingInstallCookie = nil
            }
            throw error
        }
    }

    private func finishFirmwareControl(throwing error: (any Error)? = nil) {
        waitingForFirmwareStart = false
        pendingInstallCookie = nil
        if let error { firmwareReply.fail(error) } else { firmwareReply.finish() }
    }

    private func performBlobOperation(_ write: BlobDBWrite) async throws {
        // Callers take turns rather than being turned away, as on the
        // Bluetooth transport.
        try await blobDBQueue.begin()
        defer { blobDBQueue.finish() }
        guard connection != nil else { throw WatchConnectionError.disconnected }
        let token = nextBlobToken
        nextBlobToken &+= 1
        pendingBlobToken = token
        expectedBlobStatuses = write.acceptedStatuses
        defer {
            pendingBlobToken = nil
            expectedBlobStatuses = []
        }
        try await blobDBReply.wait(timeout: .seconds(20)) {
            try self.write(try write.makeFrame(token))
        }
    }

    private func failBlobOperation(_ error: any Error) {
        pendingBlobToken = nil
        expectedBlobStatuses = []
        blobDBReply.fail(error)
    }

    private func handleConnectionState(_ state: NWConnection.State, from generation: Int) {
        guard generation == connectionGeneration else {
            return
        }
        switch state {
        case .ready:
            openContinuation?.resume()
            openContinuation = nil
        case .failed(let error):
            let shouldReconnect = (connectedWatch != nil || reconnectTask != nil) && !isManualDisconnect
            openContinuation?.resume(throwing: error)
            openContinuation = nil
            failWorkInFlight(error)
            discardConnection()
            connectedWatch = nil
            if shouldReconnect {
                scheduleReconnect()
            } else {
                eventContinuation?.yield(.disconnected(.disconnected))
            }
        case .cancelled:
            openContinuation?.resume(throwing: WatchConnectionError.disconnected)
            openContinuation = nil
        case .waiting(let error):
            // A refused connection — no emulator listening — waits here and
            // retries for as long as it is left, rather than failing. The open
            // has no deadline of its own, so only this ends it.
            openContinuation?.resume(throwing: error)
            openContinuation = nil
        default:
            break
        }
    }

    /// Cancels the link and retires its stamp, so nothing it says afterwards is
    /// taken for the next one's — including the `.cancelled` that would have
    /// ended an open still in flight, which is why that open is ended here.
    private func discardConnection() {
        openContinuation?.resume(throwing: WatchConnectionError.disconnected)
        openContinuation = nil
        connection?.cancel()
        connection = nil
        connectionGeneration += 1
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, let reconnectWatch else { return }
        eventContinuation?.yield(.reconnecting(watchID: reconnectWatch.id))
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for delay in [1, 2, 4] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, !self.isManualDisconnect else { return }
                do {
                    let watch = try await self.establishConnection(to: reconnectWatch)
                    self.reconnectTask = nil
                    self.eventContinuation?.yield(.watchUpdated(watch))
                    return
                } catch {
                    self.discardConnection()
                }
            }
            self.reconnectTask = nil
            self.eventContinuation?.yield(.disconnected(.connectionFailed))
        }
    }

    private func receiveNextMessage(from generation: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, generation == self.connectionGeneration else { return }
                if let data { self.consume([UInt8](data)) }
                if let error {
                    self.handleConnectionState(.failed(error), from: generation)
                } else if complete {
                    self.handleConnectionState(.failed(NWError.posix(.ECONNRESET)), from: generation)
                } else {
                    self.receiveNextMessage(from: generation)
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
        // One unusable frame must not swallow the reply an operation is waiting
        // for, which may well have arrived in the same read — nor fail an
        // operation whose reply it was not: a malformed app-run-state frame
        // used to end the BlobDB write and the handshake beside it.
        let batch = frameDecoder.append(bytes)
        if let failure = batch.failure {
            recordUnreadable(failure)
        }
        for frame in batch.frames {
            let awaited = isAwaitedReply(frame)
            do {
                try process(frame)
            } catch {
                recordUnreadable(error, endpoint: frame.endpoint)
                if awaited {
                    failAwaitedReply(on: frame.endpoint, error)
                }
            }
            frameContinuation?.yield(frame)
        }
    }

    private func isAwaitedReply(_ frame: PebbleProtocolFrame) -> Bool {
        switch frame.endpoint {
        case WatchVersionCodec.endpoint: versionReply.isWaiting
        case BlobDBCodec.endpoint: pendingBlobToken != nil
        case AppReorderCodec.endpoint: appReorderReply.isWaiting
        case PutBytesCodec.endpoint: transferSession != nil || pendingInstallCookie != nil
        case SystemMessageCodec.endpoint: waitingForFirmwareStart
        case AppMessageCodec.endpoint: appMessages.outstandingTransactionID != nil
        default: false
        }
    }

    /// Fails only the request whose reply could not be read. The rest are
    /// answered on endpoints of their own and are still coming.
    private func failAwaitedReply(on endpoint: UInt16, _ error: any Error) {
        switch endpoint {
        case WatchVersionCodec.endpoint: versionReply.fail(error)
        case BlobDBCodec.endpoint: failBlobOperation(error)
        case AppReorderCodec.endpoint: appReorderReply.fail(error)
        case PutBytesCodec.endpoint:
            if transferSession != nil {
                failTransfer(error)
            } else {
                finishFirmwareControl(throwing: error)
            }
        case SystemMessageCodec.endpoint: finishFirmwareControl(throwing: error)
        case AppMessageCodec.endpoint: appMessages.finishActive(throwing: error)
        default: break
        }
    }

    private func recordUnreadable(_ error: any Error, endpoint: UInt16? = nil) {
        Task { [reason = String(describing: error)] in
            await DiagnosticLog.shared.record(
                .warning,
                category: "connection",
                message: "[qemu] unreadable frame"
                    + (endpoint.map { " on endpoint \($0)" } ?? "")
                    + ": \(reason)"
            )
        }
    }

    private func process(_ frame: PebbleProtocolFrame) throws {
        Task { await DiagnosticLog.shared.recordFrame(direction: "in", frame: frame) }
        if frame.endpoint == WatchVersionCodec.endpoint, versionReply.isWaiting {
            versionReply.finish(try WatchVersionCodec.decode(frame))
        } else if frame.endpoint == PingPongCodec.endpoint {
            if case .ping(let cookie) = try PingPongCodec.decode(frame) {
                Task { try? await send(PingPongCodec.frame(for: .pong(cookie: cookie))) }
            }
        } else if PhoneVersionCodec.isRequest(frame) {
            Task { try? await send(PhoneVersionCodec.responseFrame(operatingSystem: .macOS)) }
        } else if TimeSynchronizationCodec.isTimeRequest(frame) {
            Task { try? await synchronizeTime() }
        } else if frame.endpoint == AppFetchCodec.endpoint {
            eventContinuation?.yield(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))
        } else if frame.endpoint == HealthSyncCodec.endpoint {
            eventContinuation?.yield(.healthSyncCompleted(try HealthSyncCodec.decode(frame)))
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
        } else if frame.endpoint == AppLogCodec.endpoint {
            eventContinuation?.yield(.applicationLogReceived(try AppLogCodec.decode(frame)))
        } else if frame.endpoint == AppRunStateCodec.endpoint {
            eventContinuation?.yield(.appRunStateChanged(try AppRunStateCodec.decode(frame)))
        } else if frame.endpoint == BlobDBCodec.endpoint, let token = pendingBlobToken {
            let response = try BlobDBCodec.decodeResponse(frame)
            guard response.token == token else { return }
            guard expectedBlobStatuses.contains(response.status) else {
                failBlobOperation(BlobDBClientError.rejected(response.status))
                return
            }
            pendingBlobToken = nil
            expectedBlobStatuses = []
            blobDBReply.finish()
        } else if frame.endpoint == AppReorderCodec.endpoint, appReorderReply.isWaiting {
            let result = try AppReorderCodec.decodeResult(frame)
            result == .success
                ? appReorderReply.finish()
                : appReorderReply.fail(AppReorderClientError.rejected(result))
        } else if frame.endpoint == PutBytesCodec.endpoint, transferSession != nil {
            try processPutBytesResponse(frame)
        } else if frame.endpoint == PutBytesCodec.endpoint, pendingInstallCookie != nil {
            // Not matched against the cookie that was installed: the firmware
            // answers an install from `prv_cleanup_and_send_response`, whose
            // transfer state the preceding commit already cleared, so the
            // cookie comes back as zero (issue #10). Matching it left every
            // install here waiting out its deadline.
            let response = try PutBytesCodec.decodeResponse(frame)
            pendingInstallCookie = nil
            response.result == .acknowledgement
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: PutBytesTransferError.negativeAcknowledgement)
        } else if frame.endpoint == SystemMessageCodec.endpoint, waitingForFirmwareStart {
            waitingForFirmwareStart = false
            try SystemMessageCodec.decodeFirmwareUpdateStartResponse(frame)
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: SystemMessageCodecError.updateRejected)
        } else if frame.endpoint == AppMessageCodec.endpoint {
            switch try AppMessageCodec.decode(frame) {
            case .push(let message):
                eventContinuation?.yield(.appMessageReceived(message))
            case .acknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive()
            case .negativeAcknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive(throwing: AppMessageClientError.negativeAcknowledgement)
            }
        }
    }

    /// Fails everything the emulator was in the middle of answering: a token,
    /// a transfer or a queued turn means something only on the socket that
    /// started it. Both teardown paths — a socket that failed and a disconnect
    /// that was asked for — and a connect that gave up come through here.
    private func failWorkInFlight(_ error: any Error) {
        versionReply.fail(error)
        failBlobOperation(error)
        blobDBQueue.failAll(error)
        appReorderReply.fail(error)
        failTransfer(error)
        transferQueue.failAll(error)
        finishFirmwareControl(throwing: error)
        appMessages.failAll(error)
    }
}

public enum QEMUTransportError: Error, Equatable, Sendable {
    case messageTooLarge
    case operationAlreadyInProgress
}
#endif
