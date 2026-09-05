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

    func transferObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32,
        filename: String?
    ) async throws {
        completedTransferCookie = nil
        let peripheral = try linkedPeripheral()
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

        try await transferReply.wait(timeout: .seconds(20)) {
            try handleTransferActions([firstAction], peripheral: peripheral)
        }
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        // Claimed with nothing awaited in between: a second install would take
        // over the control reply slot and strand the first.
        guard !isInstallingFirmware else {
            throw PutBytesClientError.firmwareUpdateAlreadyInProgress
        }
        isInstallingFirmware = true
        defer { isInstallingFirmware = false }
        let total = package.firmware.count + (package.resources?.count ?? 0)
        guard let byteCount = UInt32(exactly: total) else { throw PutBytesTransferError.invalidConfiguration }
        try await sendFirmwareControl(
            SystemMessageCodec.firmwareUpdateStartFrame(bytesToSend: byteCount),
            waitingForStart: true
        )
        try await installApplicationObject(
            [UInt8](package.firmware),
            objectType: package.manifest.firmware.type == "recovery" ? .recovery : .firmware,
            appBankID: 0
        )
        guard let firmwareCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
        var cookies = [firmwareCookie]
        if let resources = package.resources {
            try await installApplicationObject([UInt8](resources), objectType: .systemResource, appBankID: 0)
            guard let resourceCookie = completedTransferCookie else { throw PutBytesTransferError.invalidState }
            cookies.append(resourceCookie)
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
        try await firmwareReply.wait(timeout: .seconds(10)) {
            try sendFrame(frame, to: peripheral)
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
                    await PebbleDiagnostics.shared.record(
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
                completedTransferCookie = activeTransferSession?.completedCookie
                activeTransferSession = nil
                transferReply.finish()
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
        transferReply.fail(error)
    }
}
