import PebbleProtocol
import Foundation

/// What the phone asks a watch for and how its answers are read, whatever
/// carries the bytes: the BlobDB writes, the transfers and a firmware install,
/// the app order, app messages, the three pulls, and the frames the watch sends
/// on its own.
///
/// Each transport wrote this out for itself, and the copies drifted: the
/// emulator's answered a ping on a task of its own, logged no refusal, could not
/// install a file or pull anything, and failed an app message over a push it
/// could not read. What a transport keeps is the link — opening it, the
/// handshake, the version exchange that proves it — and it hands this a way to
/// put one frame on it.
@MainActor
final class WatchSession {
    /// Puts one frame on the link now. Throwing means the link cannot take it.
    private let send: @MainActor (PebbleProtocolFrame) throws -> Void
    private let isLinked: @MainActor () -> Bool
    private let report: @MainActor (WatchClientEvent) -> Void
    private let operatingSystem: PhoneOperatingSystem
    private let tag: String

    private let blobDBReply = PendingReply<Void>()
    private let blobDBQueue = BlobDBQueue()
    private var nextBlobDBToken: UInt16 = 1
    private var pendingBlobDBToken: UInt16?
    private var acceptedBlobDBStatuses: [BlobDBStatus] = []

    private let transferReply = PendingReply<UInt32>()
    /// Whose turn it is to transfer. The same turn-taking as BlobDB's, for the
    /// same reason.
    private let transferQueue = BlobDBQueue()
    private var activeTransferSession: PutBytesTransferSession?
    /// The token the watch gave the transfer in flight, which an abort has to
    /// name.
    private var activeTransferCookie: UInt32?

    private let firmwareReply = PendingReply<Void>()
    private var waitingForFirmwareStart = false
    private var isInstallingFirmware = false
    private var pendingInstallCookie: UInt32?

    private let appReorderReply = PendingReply<Void>()
    private let appMessages = AppMessageQueue()

    private let screenshot = WatchPull<ScreenshotCollector>(timeout: .seconds(30))
    private let logDump = WatchPull<LogDumpCollector>(timeout: .seconds(30))
    private var nextLogDumpCookie: UInt32 = 1
    private let fileBytes = WatchPull<GetBytesCollector>(timeout: .seconds(60))
    private var nextGetBytesTransactionID: UInt8 = 1

    private var healthDataLoggingProcessor = HealthDataLoggingProcessor()

    init(
        tag: String,
        operatingSystem: PhoneOperatingSystem,
        isLinked: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (PebbleProtocolFrame) throws -> Void,
        report: @escaping @MainActor (WatchClientEvent) -> Void
    ) {
        self.tag = tag
        self.operatingSystem = operatingSystem
        self.isLinked = isLinked
        self.send = send
        self.report = report
        appMessages.send = { [send] data in
            try send(AppMessageCodec.pushFrame(data))
        }
    }

    /// A transfer is under way, or an install with gaps between its transfers
    /// while the watch commits: long enough for the watch to go quiet without
    /// the link having died.
    var isTransferring: Bool {
        activeTransferSession != nil || isInstallingFirmware
    }

    private func requireLink() throws {
        guard isLinked() else { throw WatchConnectionError.disconnected }
    }

    // MARK: The link

    /// The link can carry frames again: whatever queued up while it could not
    /// goes out.
    func linkOpened() {
        appMessages.startNextIfPossible()
    }

    /// Fails everything the watch was in the middle of answering.
    ///
    /// A BlobDB token, a transfer cookie, a pull, an app reorder and a firmware
    /// control exchange all mean something only inside the session that started
    /// them. When it ends the watch will never answer any of them, and saying so
    /// now beats each one's own deadline blaming itself ten seconds later.
    func failWorkInFlight(_ error: any Error) {
        failTransfer(error)
        failBlobDBOperation(error)
        blobDBQueue.failAll(error)
        transferQueue.failAll(error)
        failPulls(error)
        appReorderReply.fail(error)
        finishFirmwareControl(throwing: error)
        // `AppModel` queues a message whose link went and flushes it on the
        // next connection, so a copy held here would be sent twice.
        appMessages.failAll(error)
    }

    /// A data-logging session id only means something inside the link that
    /// opened it. After a reconnect the watch reuses low ids freely, and reading
    /// new records with an old session's tag and item size turns them into
    /// nonsense instead of a rejection. Not part of `failWorkInFlight`: a
    /// transport reopened on the same link keeps its data-logging sessions.
    func forgetDataLoggingSessions() {
        healthDataLoggingProcessor = HealthDataLoggingProcessor()
    }

    // MARK: What the phone asks for

    func write(_ record: BlobDBRecord) async throws {
        for write in record.writes {
            try await performBlobDBOperation(write)
        }
    }

    func remove(_ key: BlobDBKey) async throws {
        for write in key.writes {
            try await performBlobDBOperation(write)
        }
    }

    private func performBlobDBOperation(_ write: BlobDBWrite) async throws {
        // Callers take turns rather than being turned away: they are unrelated
        // features on unrelated timers, and the one that lost the race used to
        // report that the watch had refused it.
        try await blobDBQueue.begin()
        defer { blobDBQueue.finish() }
        try requireLink()

        let token = nextBlobDBToken
        nextBlobDBToken &+= 1
        pendingBlobDBToken = token
        acceptedBlobDBStatuses = write.acceptedStatuses
        // A frame that cannot even be built fails the caller from inside `wait`,
        // which leaves the token behind for the next answer to match.
        defer {
            pendingBlobDBToken = nil
            acceptedBlobDBStatuses.removeAll()
        }
        try await blobDBReply.wait(timeout: .seconds(20)) {
            try self.send(try write.makeFrame(token))
        }
    }

    func reorderApplications(_ applicationIDs: [UUID]) async throws {
        try requireLink()
        guard !appReorderReply.isWaiting else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await appReorderReply.wait(timeout: .seconds(20)) {
            try send(AppReorderCodec.frame(applicationIDs: applicationIDs))
        }
    }

    func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        try requireLink()
        try await appMessages.enqueue(applicationID: applicationID, tuples: tuples)
    }

    func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await transferObject(bytes, objectType: objectType, appBankID: appBankID, filename: nil)
    }

    func installFile(_ bytes: [UInt8], filename: String) async throws {
        try await transferObject(bytes, objectType: .file, appBankID: 0, filename: filename)
    }

    /// Takes its turn behind any transfer already in flight. The watch runs one
    /// put-bytes transfer at a time, and the callers — an install the reader
    /// asked for, an app the watch fetched on its own, a language pack — are
    /// unrelated, so the one that lost the race used to be told the transfer
    /// was refused.
    @discardableResult
    private func transferObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String?
    ) async throws -> UInt32 {
        try await transferQueue.begin()
        defer { transferQueue.finish() }
        return try await transferObjectHoldingTheTurn(
            bytes,
            objectType: objectType,
            appBankID: appBankID,
            filename: filename
        )
    }

    /// For a caller already holding `transferQueue`'s turn.
    private func transferObjectHoldingTheTurn(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String?
    ) async throws -> UInt32 {
        try requireLink()
        // Unreachable while every caller holds the turn; kept so a caller that
        // does not reads as this error rather than as a stranded transfer.
        guard activeTransferSession == nil else {
            throw PutBytesClientError.transferAlreadyInProgress
        }
        var session = PutBytesTransferSession(
            bytes: bytes,
            objectType: objectType,
            appBankID: appBankID,
            filename: filename
        )
        let firstAction = try session.start()
        activeTransferSession = session
        do {
            return try await transferReply.wait(timeout: .seconds(20)) {
                try handleTransferActions([firstAction])
            }
        } catch {
            abandonTransfer()
            throw error
        }
    }

    /// Clears a transfer whose reply settled without passing through
    /// `.finished` or `failTransfer` — the deadline, or a chunk that could not
    /// be sent.
    ///
    /// Not left to the watch: it holds the transfer open until its own
    /// `PUT_TIMEOUT_MS` (30 s, `services/put_bytes/put_bytes.c`) and accepts an
    /// init only from idle (`prv_is_valid_command_for_current_state`), so the
    /// next transfer would be refused for ten seconds after this one gave up.
    /// Before the init is acknowledged there is no token to name, and that
    /// timer is all there is.
    private func abandonTransfer() {
        guard activeTransferSession != nil, !transferReply.isWaiting else { return }
        if let cookie = activeTransferCookie {
            try? send(PutBytesCodec.abortFrame(cookie: cookie))
        }
        activeTransferSession = nil
        activeTransferCookie = nil
    }

    func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // Claimed with nothing awaited in between: a second install would take
        // over the control reply slot and strand the first.
        guard !isInstallingFirmware else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        isInstallingFirmware = true
        defer { isInstallingFirmware = false }
        // One turn for the whole update rather than one per transfer: an app
        // transfer let in between the firmware and its resources would run
        // on a watch that is in the middle of replacing its firmware.
        try await transferQueue.begin()
        defer { transferQueue.finish() }
        let total = package.firmware.count + (package.resources?.count ?? 0)
        guard let byteCount = UInt32(exactly: total) else { throw PutBytesTransferError.invalidConfiguration }
        try await sendFirmwareControl(
            SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: byteCount),
            waitingForStart: true
        )
        // Bank 0, the way the official app sends it: `put_bytes.c` uses the
        // index only to name app and resource bank files, and `ObjectFirmware`
        // writes to the scratch region whatever is here. The slot chooses which
        // manifest entry to send, never a bank — and a slot number past
        // MAX_APP_BANKS would be refused outright.
        let firmwareCookie = try await transferObjectHoldingTheTurn(
            [UInt8](package.firmware),
            objectType: package.manifest.firmware.objectType,
            appBankID: 0,
            filename: nil
        )
        var cookies = [firmwareCookie]
        if let resources = package.resources {
            cookies.append(try await transferObjectHoldingTheTurn(
                [UInt8](resources),
                objectType: .systemResource,
                appBankID: 0,
                filename: nil
            ))
        }
        for cookie in cookies {
            pendingInstallCookie = cookie
            try await sendFirmwareControl(PutBytesCodec.installFrame(cookie: cookie), waitingForStart: false)
        }
        try send(SystemMessageCodec.firmwareUpdateCompleteFrame())
    }

    private func sendFirmwareControl(_ frame: PebbleProtocolFrame, waitingForStart: Bool) async throws {
        try requireLink()
        guard !firmwareReply.isWaiting else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        waitingForFirmwareStart = waitingForStart
        do {
            try await firmwareReply.wait(timeout: .seconds(10)) {
                try send(frame)
            }
        } catch {
            if !firmwareReply.isWaiting {
                waitingForFirmwareStart = false
                pendingInstallCookie = nil
            }
            throw error
        }
    }

    /// The three longer answers the watch is asked for: a screenshot, a
    /// generation of logs, a file off its flash. They differ only in which
    /// collector reads the pieces and how long the watch may go quiet.
    func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        try requireLink()
        switch request {
        case .screenshot:
            return .screenshot(try await screenshot.run(collecting: ScreenshotCollector()) {
                try send(ScreenshotCodec.requestFrame())
            })

        case .logGeneration(let generation):
            let cookie = nextLogDumpCookie
            nextLogDumpCookie &+= 1
            let dump = try await logDump.run(collecting: LogDumpCollector(cookie: cookie)) {
                try send(LogDumpCodec.requestFrame(generation: generation, cookie: cookie))
            }
            switch dump {
            case .lines(let lines): return .logLines(lines)
            case .noLogs: return .logLines(nil)
            }

        case .file(let fileRequest):
            let transactionID = nextGetBytesTransactionID
            nextGetBytesTransactionID &+= 1
            return .bytes(try await fileBytes.run(
                collecting: GetBytesCollector(transactionID: transactionID)
            ) {
                try send(GetBytesCodec.requestFrame(fileRequest, transactionID: transactionID))
            })
        }
    }

    // MARK: What the watch says

    /// Whether anything was waiting for this frame, having answered it.
    ///
    /// One case an endpoint, so that what a new one does cannot depend on where
    /// in a list it was written: the endpoints that answer more than one thing
    /// choose between them themselves. An answer with nobody waiting is not an
    /// error — a reply to a request already given up on, or an endpoint this app
    /// does not implement, is worth a line in the log and no more.
    ///
    /// A reply that cannot be read is still the reply being waited for: the
    /// wait ends with the reason at once, rather than as a timeout blaming the
    /// watch for not answering, and the error is thrown on so the frame is
    /// logged. A frame the watch sent unprompted that cannot be read fails
    /// nothing else — a malformed app-run-state frame used to end the BlobDB
    /// write and the handshake beside it.
    func answer(_ frame: PebbleProtocolFrame) throws -> Bool {
        switch frame.endpoint {
        case PingPongCodec.endpoint:
            switch try PingPongCodec.decode(frame) {
            case .ping(let cookie):
                // The watch pings the phone about once an hour and drops a link
                // it gets no pong on. Nothing is ever sent the other way: the
                // firmware answers a ping from the phone by pushing a "Ping"
                // dialog in front of whatever the reader was doing —
                // `prv_push_window` in `services/ping/service.c`,
                // unconditionally.
                try send(PingPongCodec.frame(for: .pong(cookie: cookie)))
            case .pong:
                break
            }

        case PhoneVersionCodec.endpoint:
            guard PhoneVersionCodec.isRequest(frame) else { return false }
            try send(PhoneVersionCodec.responseFrame(operatingSystem: operatingSystem))

        case TimeSynchronizationCodec.endpoint:
            guard TimeSynchronizationCodec.isTimeRequest(frame) else { return false }
            try send(TimeSynchronizationCodec.frame())

        case AppFetchCodec.endpoint:
            report(.appFetchRequested(try AppFetchCodec.decodeRequest(frame)))

        case HealthSyncCodec.endpoint:
            report(.healthSyncCompleted(try HealthSyncCodec.decode(frame)))

        case HealthDataLoggingCodec.endpoint:
            let result = try healthDataLoggingProcessor.process(frame)
            if let response = result.response { try send(response) }
            if !result.samples.isEmpty { report(.healthSamplesReceived(result.samples)) }

        case TimelineActionCodec.endpoint:
            let invocation = try TimelineActionCodec.decode(frame)
            report(.timelineActionInvoked(invocation))
            try send(TimelineActionCodec.responseFrame(itemID: invocation.itemID, succeeded: true))

        case AppRunStateCodec.endpoint:
            report(.appRunStateChanged(try AppRunStateCodec.decode(frame)))

        case ScreenshotCodec.endpoint:
            return screenshot.take(frame)

        case LogDumpCodec.endpoint:
            return logDump.take(frame)

        case GetBytesCodec.endpoint:
            return fileBytes.take(frame)

        case AppLogCodec.endpoint:
            report(.applicationLogReceived(try AppLogCodec.decode(frame)))

        case ImagingCodec.endpoint:
            report(.imageRequested(try ImagingCodec.decode(frame)))

        case AppMessageCodec.endpoint:
            answerAppMessage(frame)

        case AppReorderCodec.endpoint:
            guard appReorderReply.isWaiting else { return false }
            try answerAppReorder(frame)

        case PutBytesCodec.endpoint:
            return try answerPutBytes(frame)

        case SystemMessageCodec.endpoint:
            guard waitingForFirmwareStart else { return false }
            waitingForFirmwareStart = false
            let started = try decodingAwaitedReply {
                try SystemMessageCodec.decodeFirmwareUpdateStartResponse(frame)
            } failing: {
                finishFirmwareControl(throwing: $0)
            }
            started
                ? finishFirmwareControl()
                : finishFirmwareControl(throwing: SystemMessageCodecError.updateRejected)

        case BlobDBCodec.endpoint:
            guard pendingBlobDBToken != nil else { return false }
            try answerBlobDB(frame)

        default:
            return false
        }
        return true
    }

    private func decodingAwaitedReply<Value>(
        _ decode: () throws -> Value,
        failing fail: (any Error) -> Void
    ) throws -> Value {
        do {
            return try decode()
        } catch {
            fail(error)
            throw error
        }
    }

    private func answerBlobDB(_ frame: PebbleProtocolFrame) throws {
        let response = try decodingAwaitedReply {
            try BlobDBCodec.decodeResponse(frame)
        } failing: {
            failBlobDBOperation($0)
        }
        guard response.token == pendingBlobDBToken else { return }
        guard acceptedBlobDBStatuses.contains(response.status) else {
            // The status is the watch's whole explanation, and a refusal that
            // only reached the caller as an error value left the log showing a
            // request answered in milliseconds and nothing else.
            Task { [tag, status = response.status] in
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "blobdb",
                    message: "[\(tag)] the watch refused the write: \(status)"
                )
            }
            failBlobDBOperation(BlobDBClientError.rejected(response.status))
            return
        }
        pendingBlobDBToken = nil
        acceptedBlobDBStatuses.removeAll()
        blobDBReply.finish()
    }

    private func failBlobDBOperation(_ error: any Error) {
        pendingBlobDBToken = nil
        acceptedBlobDBStatuses.removeAll()
        blobDBReply.fail(error)
    }

    private func answerAppReorder(_ frame: PebbleProtocolFrame) throws {
        let result = try decodingAwaitedReply {
            try AppReorderCodec.decodeResult(frame)
        } failing: {
            appReorderReply.fail($0)
        }
        guard result == .success else {
            appReorderReply.fail(AppReorderClientError.rejected(result))
            return
        }
        appReorderReply.finish()
    }

    /// Whether the frame's only possible reader — the phone's message waiting
    /// for its ack, or the app for one of the watch's own — can be told apart
    /// is only known once it decodes, so one that cannot be read fails nothing.
    private func answerAppMessage(_ frame: PebbleProtocolFrame) {
        do {
            switch try AppMessageCodec.decode(frame) {
            case .push(let message):
                report(.appMessageReceived(message))
            case .acknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive()
            case .negativeAcknowledgement(let transactionID):
                guard transactionID == appMessages.outstandingTransactionID else { return }
                appMessages.finishActive(throwing: AppMessageClientError.negativeAcknowledgement)
            }
        } catch {
            Task { [tag, reason = String(describing: error)] in
                await DiagnosticLog.shared.record(
                    .warning,
                    category: "appmessage",
                    message: "[\(tag)] an app message could not be read: \(reason)"
                )
            }
        }
    }

    private func answerPutBytes(_ frame: PebbleProtocolFrame) throws -> Bool {
        if activeTransferSession != nil {
            try answerTransfer(frame)
            return true
        }
        guard pendingInstallCookie != nil else { return false }
        // Not matched against the cookie that was installed: the firmware
        // answers an install from `prv_cleanup_and_send_response`, whose
        // transfer state the preceding commit already cleared, so the cookie
        // comes back as zero (issue #10).
        let response = try decodingAwaitedReply {
            try PutBytesCodec.decodeResponse(frame)
        } failing: {
            finishFirmwareControl(throwing: $0)
        }
        pendingInstallCookie = nil
        response.result == .acknowledgement
            ? finishFirmwareControl()
            : finishFirmwareControl(throwing: PutBytesTransferError.negativeAcknowledgement)
        return true
    }

    private func answerTransfer(_ frame: PebbleProtocolFrame) throws {
        guard var session = activeTransferSession else { return }
        let response = try decodingAwaitedReply {
            try PutBytesCodec.decodeResponse(frame)
        } failing: {
            failTransfer($0)
        }
        do {
            let actions = try session.receive(response)
            activeTransferSession = session
            activeTransferCookie = response.cookie
            try handleTransferActions(actions)
            // Each chunk the watch acknowledges puts the deadline back: a
            // transfer is megabytes and only silence means it has stopped.
            if activeTransferSession != nil {
                transferReply.extendDeadline(.seconds(20))
            }
        } catch {
            try? send(PutBytesCodec.abortFrame(cookie: response.cookie))
            failTransfer(error)
        }
    }

    private func handleTransferActions(_ actions: [PutBytesTransferAction]) throws {
        for action in actions {
            switch action {
            case .send(let frame):
                try send(frame)
            case .progress(let progress):
                report(.transferProgress(progress))
            case .finished:
                let cookie = activeTransferSession?.completedCookie
                activeTransferSession = nil
                activeTransferCookie = nil
                if let cookie {
                    transferReply.finish(cookie)
                } else {
                    transferReply.fail(PutBytesTransferError.invalidState)
                }
            }
        }
    }

    private func failTransfer(_ error: any Error) {
        activeTransferSession = nil
        activeTransferCookie = nil
        transferReply.fail(error)
    }

    private func finishFirmwareControl(throwing error: (any Error)? = nil) {
        waitingForFirmwareStart = false
        pendingInstallCookie = nil
        if let error { firmwareReply.fail(error) } else { firmwareReply.finish() }
    }

    private func failPulls(_ error: any Error) {
        screenshot.finish(.failure(error))
        logDump.finish(.failure(error))
        fileBytes.finish(.failure(error))
    }
}
