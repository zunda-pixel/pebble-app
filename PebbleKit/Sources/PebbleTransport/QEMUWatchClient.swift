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
    private let versionReply = PendingReply<WatchVersionInformation>()
    /// Lazy so that it can hold on to this client weakly: an initializer
    /// cannot hand out `self` before every property is set.
    private lazy var session = WatchSession(
        tag: "qemu",
        operatingSystem: .macOS,
        isLinked: { [weak self] in self?.connection != nil },
        send: { [weak self] frame in
            guard let self else { throw WatchConnectionError.disconnected }
            try self.write(frame)
        },
        report: { [weak self] event in self?.eventContinuation?.yield(event) }
    )
    private var reconnectWatch: WatchConnectionTarget?
    private var connectedWatch: ConnectedWatch?
    private var reconnectTask: Task<Void, Never>?
    private var isManualDisconnect = false

    public init(host: String = "127.0.0.1", port: UInt16 = 12_344) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port) ?? 12_344
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
        // The loop's next attempt would find this link and, failing to open a
        // second, close the one this opened.
        reconnectTask?.cancel()
        reconnectTask = nil
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
        session.forgetDataLoggingSessions()
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
            session.linkOpened()
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
        try await session.reorderApplications(applicationIDs)
    }

    public func respondToAppFetch(with status: AppFetchResponseStatus) async throws {
        try await send(AppFetchCodec.responseFrame(status: status))
    }

    public func sendAppMessage(applicationID: UUID, tuples: [AppMessageTuple]) async throws {
        try await session.sendAppMessage(applicationID: applicationID, tuples: tuples)
    }

    public func respondToAppMessage(transactionID: UInt8, acknowledged: Bool) async throws {
        try await send(AppMessageCodec.resultFrame(
            transactionID: transactionID,
            acknowledged: acknowledged
        ))
    }

    public func write(_ record: BlobDBRecord) async throws {
        try await session.write(record)
    }

    public func remove(_ key: BlobDBKey) async throws {
        try await session.remove(key)
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

    public func pull(_ request: WatchPullRequest) async throws -> WatchPullAnswer {
        try await session.pull(request)
    }

    public func setApplicationLoggingEnabled(_ isEnabled: Bool) async throws {
        try await send(AppLogCodec.enableFrame(isEnabled))
    }

    public func installFile(_ bytes: [UInt8], filename: String) async throws {
        try await session.installFile(bytes, filename: filename)
    }

    public func installApplicationObject(
        _ bytes: [UInt8],
        objectType: PutBytesObjectType,
        appBankID: UInt32
    ) async throws {
        try await session.installApplicationObject(bytes, objectType: objectType, appBankID: appBankID)
    }

    public func installFirmware(_ package: PBZFirmwarePackage) async throws {
        try await session.installFirmware(package)
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
                } catch WatchConnectionError.connectionAlreadyInProgress {
                    // Someone else's link, and a healthy one.
                    self.reconnectTask = nil
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
            do {
                try process(frame)
            } catch {
                recordUnreadable(error, endpoint: frame.endpoint)
            }
            frameContinuation?.yield(frame)
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
            // The handshake's own answer, and so this link's rather than the
            // session's. Unreadable, it still ends the wait.
            do {
                versionReply.finish(try WatchVersionCodec.decode(frame))
            } catch {
                versionReply.fail(error)
                throw error
            }
            return
        }
        if try session.answer(frame) { return }
        guard CompanionFrame(endpoint: frame.endpoint) == nil else { return }
        Task { [frame] in
            await DiagnosticLog.shared.recordUnansweredFrame(frame, tag: "qemu")
        }
    }

    /// Fails everything the emulator was in the middle of answering: a token,
    /// a transfer or a queued turn means something only on the socket that
    /// started it. Both teardown paths — a socket that failed and a disconnect
    /// that was asked for — and a connect that gave up come through here.
    private func failWorkInFlight(_ error: any Error) {
        versionReply.fail(error)
        session.failWorkInFlight(error)
    }
}

public enum QEMUTransportError: Error, Equatable, Sendable {
    case messageTooLarge
    case operationAlreadyInProgress
}
#endif
