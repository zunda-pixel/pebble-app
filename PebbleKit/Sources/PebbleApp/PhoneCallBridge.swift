import PebbleProtocol
import Foundation

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


/// A phone that tells the watch nothing about calls.
///
/// Two reasons, and they are not the same one.
///
/// On **iOS** the watch is already told, by iOS itself: it subscribes to ANCS
/// and the firmware turns an incoming-call notification into a call with the
/// caller's name (`ancs_phone_call.c:64`, `phone_call_util_create_caller`).
/// Sending the same call over Pebble Protocol as well made the two race, and
/// `prv_handle_incoming_call` takes one call at a time
/// (`services/phone_call/service.c:110`). Losing that race cost the caller's
/// name — `CXCallObserver` never says who is calling — and won the Android
/// call UI, whose duration timer counts a call still ringing and whose hangup
/// reaches an app that iOS forbids from ending a carrier call. `PhoneCallSource_PP`
/// means Android to the firmware, and it is right to (#80).
///
/// On **macOS** there is no telephony to read at all.
@MainActor
final class NoCallSource: SystemCallSource {
    var onEvent: ((PhoneCallEvent) -> Void)?
    func start() {}
    func stop() {}
    func perform(_ action: PhoneCallAction) {}
}

@MainActor
func makeSystemCallSource() -> any SystemCallSource {
    NoCallSource()
}
