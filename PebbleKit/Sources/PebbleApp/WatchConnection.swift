public import PebbleProtocol
public import Foundation
// `WatchConnection` is public and `@Observable`, so the conformance the macro
// writes is public too.
public import Observation

public enum WatchConnectionPhase: Equatable, Sendable {
    case connected
    case reconnecting
    case disconnected(WatchConnectionError)
}

/// What the bytes going to a watch are for.
///
/// A count on its own cannot be shown anywhere: the same watch takes an
/// application, a firmware image and a language pack through the same transfer,
/// and two watches can be taking different ones at the same moment. Knowing
/// which of them a progress belongs to is what lets a screen show its own.
public enum WatchTransferKind: Equatable, Sendable {
    case application(UUID)
    case firmware
    case languagePack
}

/// Each connection owns its own transport client, event observation and
/// per-watch companion state, so several watches can be connected at once.
@MainActor
@Observable
public final class WatchConnection: Identifiable {
    public let client: any WatchClient
    public private(set) var watch: ConnectedWatch
    public private(set) var phase: WatchConnectionPhase = .connected
    /// The watch is the thing doing the work, so the count belongs to it rather
    /// than to whichever kind of transfer is running somewhere.
    public private(set) var transferProgress: PutBytesTransferProgress?
    public private(set) var transferKind: WatchTransferKind?

    /// The app this watch asked for, while it is being sent.
    ///
    /// Per watch because the request is: two watches launching two apps ask
    /// separately, and one of them waiting is no reason to answer the other with
    /// "busy".
    @ObservationIgnored var appFetchTask: Task<Void, Never>?

    @ObservationIgnored var synchronizedNotificationAppRecords: [String: [UInt8]] = [:]
    @ObservationIgnored var synchronizedAppGlances: [UUID: [UInt8]] = [:]
    @ObservationIgnored private var needsPostReconnectSync = false
    @ObservationIgnored let voiceCoordinator: VoiceSessionCoordinator
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?

    public nonisolated var id: WatchID {
        watchID
    }

    private nonisolated let watchID: WatchID

    public var isConnected: Bool {
        phase == .connected
    }

    public var isFetchingApplication: Bool {
        appFetchTask != nil
    }

    public func transferProgress(for kind: WatchTransferKind) -> PutBytesTransferProgress? {
        transferKind == kind ? transferProgress : nil
    }

    /// The application being sent to this watch, if that is what the transfer is.
    public var applicationBeingSent: UUID? {
        guard case .application(let id) = transferKind else { return nil }
        return id
    }

    init(
        client: any WatchClient,
        watch: ConnectedWatch,
        voiceProvider: (any PebbleVoiceTranscriptionProvider)? = nil
    ) {
        self.client = client
        self.watch = watch
        self.watchID = watch.id
        voiceCoordinator = VoiceSessionCoordinator(provider: voiceProvider) { [client] frame in
            try await client.send(frame)
        }
    }

    func startObserving(
        onEvent: @escaping @MainActor (WatchConnection, WatchClientEvent) -> Void,
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

    private func apply(_ event: WatchClientEvent) {
        switch event {
        case .watchUpdated(let watch):
            self.watch = watch
            phase = .connected
        case .transferProgress(let progress):
            transferProgress = progress
        case .reconnecting:
            phase = .reconnecting
            needsPostReconnectSync = true
            synchronizedNotificationAppRecords = [:]
            synchronizedAppGlances = [:]
            endTransfer()
        case .disconnected(let error):
            phase = .disconnected(error)
            synchronizedNotificationAppRecords = [:]
            synchronizedAppGlances = [:]
            endTransfer()
            cancelApplicationFetch()
            voiceCoordinator.reset()
        default:
            break
        }
    }

    // So a bar appears at once and the count left by the last transfer is not
    // mistaken for this one.
    func beginTransfer(_ kind: WatchTransferKind) {
        transferKind = kind
        transferProgress = PutBytesTransferProgress(bytesSent: 0, totalBytes: 0)
    }

    func endTransfer() {
        transferProgress = nil
        transferKind = nil
    }

    func cancelApplicationFetch() {
        appFetchTask?.cancel()
        appFetchTask = nil
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
        cancelApplicationFetch()
        endTransfer()
        voiceCoordinator.reset()
        await client.disconnect(from: watch)
    }
}
