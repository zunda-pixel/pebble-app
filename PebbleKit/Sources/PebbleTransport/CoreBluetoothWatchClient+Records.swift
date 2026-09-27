public import PebbleProtocol
import CoreBluetooth
public import Foundation

/// What the phone writes into the watch's databases, and the bytes it sends it.
///
/// One seam, opened by collapsing the twenty typed BlobDB methods into
/// `write(_:)` and `remove(_:)`: what is left here answers by token — a BlobDB
/// status, a put-bytes acknowledgement, an app-reorder result — and nothing in
/// it touches the link or the handshake. The state each waits on had to widen
/// from `private` to `internal` for the move; `internal` reaches no further
/// than this module.
extension CoreBluetoothWatchClient {
    public func reorderApplications(_ applicationIDs: [UUID]) async throws {
        let peripheral = try linkedPeripheral()
        guard !appReorderReply.isWaiting else {
            throw AppReorderClientError.operationAlreadyInProgress
        }
        try await appReorderReply.wait(timeout: .seconds(20)) {
            try sendFrame(AppReorderCodec.frame(applicationIDs: applicationIDs), to: peripheral)
        }
    }

    public func write(_ record: BlobDBRecord) async throws {
        for write in record.writes {
            try await performBlobDBOperation(write)
        }
    }

    public func remove(_ key: BlobDBKey) async throws {
        for write in key.writes {
            try await performBlobDBOperation(write)
        }
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await transferObject(bytes, objectType: objectType, appBankID: appBankID, filename: nil)
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        try await transferObject(bytes, objectType: .file, appBankID: 0, filename: filename)
    }

    /// Takes its turn behind any transfer already in flight. The watch runs one
    /// put-bytes transfer at a time, and the callers — an install the reader
    /// asked for, an app the watch fetched on its own, a language pack — are
    /// unrelated, so the one that lost the race used to be told the transfer
    /// was refused.
    @discardableResult
    func transferObject(
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
    func transferObjectHoldingTheTurn(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String?
    ) async throws -> UInt32 {
        let peripheral = try linkedPeripheral()
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
                try handleTransferActions([firstAction], peripheral: peripheral)
            }
        } catch {
            abandonTransfer(on: peripheral)
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
    func abandonTransfer(on peripheral: CBPeripheral) {
        guard activeTransferSession != nil, !transferReply.isWaiting else { return }
        if let cookie = activeTransferCookie {
            try? sendFrame(PutBytesCodec.abortFrame(cookie: cookie), to: peripheral)
        }
        activeTransferSession = nil
        activeTransferCookie = nil
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
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
        try await send(SystemMessageCodec.firmwareUpdateCompleteFrame())
    }

    func sendFirmwareControl(_ frame: PebbleProtocolFrame, waitingForStart: Bool) async throws {
        guard let peripheral = connectedPeripheral else { throw WatchConnectionError.disconnected }
        guard !firmwareReply.isWaiting else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        self.waitingForFirmwareStart = waitingForStart
        do {
            try await firmwareReply.wait(timeout: .seconds(10)) {
                try sendFrame(frame, to: peripheral)
            }
        } catch {
            if !firmwareReply.isWaiting {
                waitingForFirmwareStart = false
                pendingInstallCookie = nil
            }
            throw error
        }
    }

    func performBlobDBOperation(_ write: BlobDBWrite) async throws {
        // Callers take turns rather than being turned away: they are unrelated
        // features on unrelated timers, and the one that lost the race used to
        // report that the watch had refused it.
        try await blobDBQueue.begin()
        defer { blobDBQueue.finish() }
        let peripheral = try linkedPeripheral()

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
            try sendFrame(try write.makeFrame(token), to: peripheral)
        }
    }

    func answerPutBytes(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws -> Bool {
        if activeTransferSession != nil {
            try processPutBytesResponse(frame, peripheral: peripheral)
            return true
        }
        guard pendingInstallCookie != nil else { return false }
        // The install cookie comes back as zero: the firmware answers from
        // `prv_cleanup_and_send_response`, whose transfer state the preceding
        // commit already cleared.
        let response = try PutBytesCodec.decodeResponse(frame)
        pendingInstallCookie = nil
        response.result == .acknowledgement
            ? finishFirmwareControl()
            : finishFirmwareControl(throwing: PutBytesTransferError.negativeAcknowledgement)
        return true
    }

    func finishFirmwareControl(throwing error: (any Error)? = nil) {
        waitingForFirmwareStart = false
        pendingInstallCookie = nil
        if let error { firmwareReply.fail(error) } else { firmwareReply.finish() }
    }

    func processPutBytesResponse(
        _ frame: PebbleProtocolFrame,
        peripheral: CBPeripheral
    ) throws {
        guard var session = activeTransferSession else {
            return
        }
        let response = try PutBytesCodec.decodeResponse(frame)
        do {
            let actions = try session.receive(response)
            activeTransferSession = session
            activeTransferCookie = response.cookie
            try handleTransferActions(actions, peripheral: peripheral)
            updateTransferTimeout()
        } catch {
            try? sendFrame(PutBytesCodec.abortFrame(cookie: response.cookie), to: peripheral)
            failTransfer(error)
        }
    }

    func processBlobDBResponse(_ frame: PebbleProtocolFrame) {
        do {
            let response = try BlobDBCodec.decodeResponse(frame)
            guard response.token == pendingBlobDBToken else { return }
            guard acceptedBlobDBStatuses.contains(response.status) else {
                // The status is the watch's whole explanation, and a refusal that
                // only reached the caller as an error value left the log showing a
                // request answered in milliseconds and nothing else.
                Task { [tag = clientTag, status = response.status] in
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
        } catch {
            failBlobDBOperation(error)
        }
    }

    func processAppReorderResponse(_ frame: PebbleProtocolFrame) {
        do {
            let result = try AppReorderCodec.decodeResult(frame)
            guard result == .success else {
                failAppReorder(AppReorderClientError.rejected(result))
                return
            }
            appReorderReply.finish()
        } catch {
            failAppReorder(error)
        }
    }

    func failAppReorder(_ error: any Error) {
        appReorderReply.fail(error)
    }

    func failBlobDBOperation(_ error: any Error) {
        pendingBlobDBToken = nil
        acceptedBlobDBStatuses.removeAll()
        blobDBReply.fail(error)
    }

    func handleTransferActions(
        _ actions: [PutBytesTransferAction],
        peripheral: CBPeripheral
    ) throws {
        for action in actions {
            switch action {
            case .send(let frame):
                try sendFrame(frame, to: peripheral)
            case .progress(let progress):
                eventContinuation?.yield(.transferProgress(progress))
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

    // Each chunk the watch acknowledges puts the deadline back: a transfer is
    // megabytes and only silence means it has stopped.
    func updateTransferTimeout() {
        guard activeTransferSession != nil else {
            transferReply.cancelDeadline()
            return
        }
        transferReply.extendDeadline(.seconds(20))
    }

    func failTransfer(_ error: any Error) {
        activeTransferSession = nil
        activeTransferCookie = nil
        transferReply.fail(error)
    }
}
