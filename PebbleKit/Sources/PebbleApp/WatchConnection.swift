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
    @ObservationIgnored var appFetchTask: Task<Void, Never>? {
        didSet { isFetchingApplication = appFetchTask != nil }
    }
    public private(set) var isFetchingApplication = false
    /// The library operation this watch's fetch took, if it took one. Only
    /// that one is this link's to end when it drops: the operation is shared by
    /// every watch, and another's import may be holding it.
    @ObservationIgnored var ownedApplicationOperation: ApplicationManagementOperation?
    /// Which fetch `appFetchTask` is, for the task itself to check: a task
    /// cannot compare itself against the handle it was stored under.
    @ObservationIgnored var appFetchToken: UUID?

    @ObservationIgnored var synchronizedNotificationAppRecords: [String: [UInt8]] = [:]
    @ObservationIgnored var synchronizedAppGlances: [UUID: [UInt8]] = [:]
    @ObservationIgnored private var needsPostReconnectSync = false
    @ObservationIgnored let voiceCoordinator: VoiceSessionCoordinator
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var framesTask: Task<Void, Never>?
    @ObservationIgnored private var appMessagesTask: Task<Void, Never>?
    @ObservationIgnored private var appMessages: AsyncStream<AppMessageData>.Continuation?

    public nonisolated var id: WatchID {
        watchID
    }

    private nonisolated let watchID: WatchID

    public var isConnected: Bool {
        phase == .connected
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
        voiceProvider: (any VoiceTranscriptionProvider)? = nil
    ) {
        self.client = client
        self.watch = watch
        self.watchID = watch.id
        voiceCoordinator = VoiceSessionCoordinator(provider: voiceProvider) { [client] frame in
            try await client.send(frame)
        }
    }

    /// `onAppMessage` is given one message at a time, in the order the watch
    /// sent them: a task per message let a later one reach the app's script
    /// first whenever the earlier one waited longer to load it.
    func startObserving(
        onEvent: @escaping @MainActor (WatchConnection, WatchClientEvent) -> Void,
        onFrame: @escaping @MainActor (WatchConnection, PebbleProtocolFrame) async -> Void,
        onAppMessage: @escaping @MainActor (WatchConnection, AppMessageData) async -> Void
    ) {
        stopDeliveringAppMessages()
        let (messages, continuation) = AsyncStream.makeStream(of: AppMessageData.self)
        appMessages = continuation
        appMessagesTask = Task { [weak self] in
            for await message in messages {
                guard !Task.isCancelled, let self else {
                    return
                }
                await onAppMessage(self, message)
            }
        }
        eventsTask?.cancel()
        eventsTask = Task { [weak self, client] in
            for await event in client.events() {
                guard !Task.isCancelled, let self else {
                    return
                }
                self.apply(event)
                // Queued rather than awaited: a script slow to answer must not
                // hold up the events behind it, a disconnect among them.
                if case .appMessageReceived(let message) = event {
                    self.appMessages?.yield(message)
                }
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
            voiceCoordinator.reset()
        case .disconnected(let error):
            phase = .disconnected(error)
            synchronizedNotificationAppRecords = [:]
            synchronizedAppGlances = [:]
            endTransfer()
            cancelApplicationFetch()
            stopDeliveringAppMessages()
            voiceCoordinator.reset()
        default:
            break
        }
    }

    private func stopDeliveringAppMessages() {
        appMessages?.finish()
        appMessages = nil
        appMessagesTask?.cancel()
        appMessagesTask = nil
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
        appFetchToken = nil
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
        stopDeliveringAppMessages()
        endTransfer()
        voiceCoordinator.reset()
        await client.disconnect(from: watch)
    }
}
