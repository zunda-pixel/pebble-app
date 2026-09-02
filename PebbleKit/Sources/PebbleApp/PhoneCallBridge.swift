import PebbleProtocol
import Foundation
#if os(iOS)
import CallKit
#endif

enum PhoneCallEvent: Equatable, Sendable {
    case ringing(cookie: UInt32, callerNumber: String, callerName: String?)
    case connected(cookie: UInt32)
    case ended(cookie: UInt32)
}

@MainActor
protocol SystemCallSource: AnyObject {
    var onEvent: ((PhoneCallEvent) -> Void)? { get set }
    func start()
    func stop()
    func perform(_ action: PhoneCallAction)
}

@MainActor
final class PhoneCallCoordinator {
    private let send: (PebbleProtocolFrame) async throws -> Void
    private let source: any SystemCallSource
    private var activeCookie: UInt32?

    init(
        source: any SystemCallSource,
        send: @escaping (PebbleProtocolFrame) async throws -> Void
    ) {
        self.source = source
        self.send = send
        source.onEvent = { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func start() {
        source.start()
    }

    func stop() {
        activeCookie = nil
        source.stop()
    }

    func handleFrame(_ frame: PebbleProtocolFrame) {
        guard let action = try? PhoneControlCodec.decode(frame) else {
            return
        }
        source.perform(action)
    }

    private func handleEvent(_ event: PhoneCallEvent) {
        Task { [send] in
            switch event {
            case .ringing(let cookie, let number, let name):
                activeCookie = cookie
                try? await send(PhoneControlCodec.incomingCallFrame(
                    cookie: cookie,
                    callerNumber: number,
                    callerName: name
                ))
            case .connected(let cookie):
                activeCookie = cookie
                try? await send(PhoneControlCodec.callStartFrame(cookie: cookie))
            case .ended(let cookie):
                guard activeCookie == cookie else { return }
                activeCookie = nil
                try? await send(PhoneControlCodec.callEndFrame(cookie: cookie))
            }
        }
    }
}

#if os(iOS)
@MainActor
final class CallKitCallSource: NSObject, SystemCallSource, CXCallObserverDelegate {
    var onEvent: ((PhoneCallEvent) -> Void)?
    private var observer: CXCallObserver?
    private var cookies: [UUID: UInt32] = [:]
    private var connectedCalls: Set<UUID> = []

    func start() {
        guard observer == nil else {
            return
        }
        let observer = CXCallObserver()
        observer.setDelegate(self, queue: .main)
        self.observer = observer
    }

    func stop() {
        observer?.setDelegate(nil, queue: nil)
        observer = nil
        cookies = [:]
        connectedCalls = []
    }

    func perform(_ action: PhoneCallAction) {
        // iOS does not let third-party apps answer or end carrier calls.
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let uuid = call.uuid
        let hasEnded = call.hasEnded
        let hasConnected = call.hasConnected
        let isOutgoing = call.isOutgoing
        MainActor.assumeIsolated {
            handleChange(uuid: uuid, hasEnded: hasEnded, hasConnected: hasConnected, isOutgoing: isOutgoing)
        }
    }

    private func handleChange(uuid: UUID, hasEnded: Bool, hasConnected: Bool, isOutgoing: Bool) {
        if hasEnded {
            guard let cookie = cookies.removeValue(forKey: uuid) else { return }
            connectedCalls.remove(uuid)
            onEvent?(.ended(cookie: cookie))
            return
        }
        let cookie = cookies[uuid] ?? {
            let cookie = UInt32.random(in: 1...UInt32.max)
            cookies[uuid] = cookie
            return cookie
        }()
        if hasConnected {
            guard !connectedCalls.contains(uuid) else { return }
            connectedCalls.insert(uuid)
            onEvent?(.connected(cookie: cookie))
        } else if !isOutgoing {
            // CallKit never exposes the caller's number or name to a companion app.
            onEvent?(.ringing(
                cookie: cookie,
                callerNumber: "",
                callerName: String(localized: "Incoming Call", bundle: .module)
            ))
        }
    }
}
#endif

@MainActor
final class UnsupportedCallSource: SystemCallSource {
    var onEvent: ((PhoneCallEvent) -> Void)?
    func start() {}
    func stop() {}
    func perform(_ action: PhoneCallAction) {}
}

@MainActor
func makeSystemCallSource() -> any SystemCallSource {
    #if os(iOS)
    CallKitCallSource()
    #else
    UnsupportedCallSource()
    #endif
}
