public import API
import Foundation
import Observation

public enum WatchConnectionPhase: Equatable, Sendable {
    case connected
    case reconnecting
    case disconnected(PebbleConnectionError)
}

/// One live link to a watch. Each connection owns its own transport client,
/// event/frame observation, and per-watch companion state, so several watches
/// can be connected at the same time.
@MainActor
@Observable
public final class WatchConnection: Identifiable {
    public let client: any PebbleClient
    public private(set) var device: PebbleDevice
    public private(set) var phase: WatchConnectionPhase = .connected

    @ObservationIgnored var synchronizedNotificationAppRecords: [String: [UInt8]] = [:]
    @ObservationIgnored var blobDBTokenCounter: UInt16 = 0x4000
    @ObservationIgnored private var needsPostReconnectSync = false
    @ObservationIgnored private(set) var voiceCoordinator: VoiceSessionCoordinator!
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
        case .reconnecting:
            phase = .reconnecting
            needsPostReconnectSync = true
            synchronizedNotificationAppRecords = [:]
        case .disconnected(let error):
            phase = .disconnected(error)
            synchronizedNotificationAppRecords = [:]
            voiceCoordinator.reset()
        default:
            break
        }
    }

    /// Returns whether the watch just came back from a reconnect (and
    /// therefore needs a full data resync), clearing the flag.
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
