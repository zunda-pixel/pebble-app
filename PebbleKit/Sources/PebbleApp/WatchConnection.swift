public import PebbleProtocol
import Foundation
// `WatchConnection` is public and `@Observable`, so the conformance the macro
// writes is public too.
public import Observation

public enum WatchConnectionPhase: Equatable, Sendable {
    case connected
    case reconnecting
    case disconnected(PebbleConnectionError)
}

/// Each connection owns its own transport client, event observation and
/// per-watch companion state, so several watches can be connected at once.
@MainActor
@Observable
public final class WatchConnection: Identifiable {
    public let client: any PebbleClient
    public private(set) var device: PebbleDevice
    public private(set) var phase: WatchConnectionPhase = .connected
    /// The watch is the thing doing the work, so the count belongs to it rather
    /// than to whichever kind of transfer is running somewhere.
    public private(set) var transferProgress: PutBytesTransferProgress?

    @ObservationIgnored var synchronizedNotificationAppRecords: [String: [UInt8]] = [:]
    @ObservationIgnored private var needsPostReconnectSync = false
    @ObservationIgnored let voiceCoordinator: VoiceSessionCoordinator
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?

    public nonisolated var id: String {
        deviceID
    }

    private nonisolated let deviceID: String

    public var isConnected: Bool {
        phase == .connected
    }

    init(client: any PebbleClient, device: PebbleDevice) {
        self.client = client
        self.device = device
        self.deviceID = device.id
        voiceCoordinator = VoiceSessionCoordinator(provider: nil) { [client] frame in
            try await client.send(frame)
        }
    }

    func startObserving(
        onEvent: @escaping @MainActor (WatchConnection, PebbleClientEvent) -> Void,
        onFrame: @escaping @MainActor (WatchConnection, PebbleProtocolFrame) async -> Void
    ) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self, client] in
            for await event in client.events() {
                guard !Task.isCancelled, let self else {
                    return
                }
                self.apply(event)
                onEvent(self, event)
            }
        }
        framesTask?.cancel()
        framesTask = Task { [weak self, client] in
            for await frame in client.frames() {
                guard !Task.isCancelled, let self else {
                    return
                }
                await onFrame(self, frame)
            }
        }
    }

    private func apply(_ event: PebbleClientEvent) {
        switch event {
        case .deviceUpdated(let device):
            self.device = device
            phase = .connected
        case .transferProgress(let progress):
            transferProgress = progress
        case .reconnecting:
            phase = .reconnecting
            needsPostReconnectSync = true
            synchronizedNotificationAppRecords = [:]
            transferProgress = nil
        case .disconnected(let error):
            phase = .disconnected(error)
            synchronizedNotificationAppRecords = [:]
            transferProgress = nil
            voiceCoordinator.reset()
        default:
            break
        }
    }

    // So a bar appears at once and the count left by the last transfer is not
    // mistaken for this one.
    func beginTransfer() {
        transferProgress = PutBytesTransferProgress(bytesSent: 0, totalBytes: 0)
    }

    func endTransfer() {
        transferProgress = nil
    }

    func consumePostReconnectSync() -> Bool {
        defer { needsPostReconnectSync = false }
        return needsPostReconnectSync
    }

    func close() async {
        eventsTask?.cancel()
        eventsTask = nil
        framesTask?.cancel()
        framesTask = nil
        voiceCoordinator.reset()
        await client.disconnect(from: device)
    }
}
