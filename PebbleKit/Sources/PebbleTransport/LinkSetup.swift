import PebbleProtocol
import Foundation

/// Where a link stands between connecting and having a protocol session: whether
/// it is bonded, which side hosts the transport, and whether this side still owes
/// the watch a ResetComplete.
///
/// Three fields that have to move together. A watch that is not bonded yet
/// publishes its protocol service only once the link is encrypted, so the phone
/// reasonably concludes it must host the transport itself and then has to undo
/// that when the watch's own service turns up; the choice is per link, and
/// carrying the last one over sends the handshake down a transport nobody is
/// listening on. Deciding all of this here, with no CoreBluetooth in sight,
/// is what makes it something a test can walk through.
struct LinkSetup: Equatable {
    enum Pairing: Equatable {
        /// Services have not been inspected yet.
        case unknown
        /// Waiting for the watch to report its connectivity status.
        case checking
        /// The watch has been asked to pair; waiting for the reader to accept.
        case pairing
        /// The link is bonded, or the watch has no pairing service.
        case ready
    }

    /// Which side of the link hosts the protocol service.
    enum Transport: Equatable {
        /// The watch hosts it and the phone writes to a characteristic.
        case reversed
        /// The phone hosts it and notifies the watch, which subscribed to it.
        case forward
    }

    /// What the connectivity characteristic asks the client to do next.
    enum ConnectivityDecision: Equatable {
        /// Nothing to do: the link is already bonded, or the reader is already
        /// being asked.
        case wait
        /// Not bonded. Only the watch can start bonding, so it has to be asked
        /// for a security request.
        case askWatchToPair
        /// Bonded. `wasPairing` is true when the reader had to accept a prompt,
        /// which is the case that needs the rest of the handshake given a fresh
        /// deadline.
        case ready(wasPairing: Bool)
    }

    private(set) var pairing = Pairing.unknown
    private(set) var transport = Transport.reversed
    private(set) var hasSentResetComplete = false
    /// Whether the watch asked for a session while there was still no way to
    /// answer it. Kept so the answer can go out as soon as there is one.
    private(set) var watchAskedBeforeThereWasAnAnswer = false

    /// A fresh link, keeping nothing from the last one.
    mutating func reset() {
        self = LinkSetup()
    }

    mutating func noteCheckingPairing() {
        pairing = .checking
    }

    /// A watch with no pairing service to read: there is nothing to wait for, and
    /// one that needs pairing fails later anyway.
    mutating func noteNoPairingService() {
        pairing = .ready
    }

    mutating func apply(_ status: PebbleConnectivityStatus) -> ConnectivityDecision {
        guard pairing != .ready else { return .wait }
        if status.isReadyForProtocol {
            let wasPairing = pairing == .pairing
            pairing = .ready
            return .ready(wasPairing: wasPairing)
        }
        guard pairing != .pairing else { return .wait }
        pairing = .pairing
        return .askWatchToPair
    }

    /// Whether the protocol may be started at all: subscribing before the link is
    /// known to be bonded fails on a watch that is not paired yet.
    var mayStartProtocol: Bool {
        pairing == .ready
    }

    /// Takes over hosting the transport. False when the phone is already hosting,
    /// so the GATT registration is not made twice.
    mutating func hostTransportOnPhone() -> Bool {
        guard transport != .forward else { return false }
        transport = .forward
        return true
    }

    /// Hands the transport back to the watch now that it has published its own
    /// service. False when the phone was not hosting it.
    mutating func handTransportBackToWatch() -> Bool {
        guard transport == .forward else { return false }
        transport = .reversed
        return true
    }

    /// Whether this side still owes a ResetComplete. The side that answers one
    /// must not send a second: the watch reads that as a request to tear the
    /// session down again.
    mutating func claimResetComplete() -> Bool {
        guard !hasSentResetComplete else { return false }
        hasSentResetComplete = true
        return true
    }

    mutating func forgetResetComplete() {
        hasSentResetComplete = false
    }

    /// What to send now that there is a way to answer through, given whatever the
    /// watch has already asked for.
    ///
    /// A request that arrived too early is answered rather than forgotten. The
    /// watch is waiting for that answer and will not take a fresh request in its
    /// place, so asking again buys nothing and costs its retry timer: 1.15
    /// seconds of both sides waiting, measured on the reader's phone against 26
    /// milliseconds when the phone asked first.
    ///
    /// A stale one is no worse than not answering. The watch that has moved on
    /// asks again, and `steps(for:hasSession:)` answers a request whether or not
    /// a ResetComplete was already owed.
    ///
    /// `askingIfNeeded` is false on the transport the phone hosts, where the
    /// watch sends the request once it has subscribed and one from here as well
    /// leaves both sides mid-handshake.
    mutating func stepsToOpenTheSession(askingIfNeeded: Bool) -> [PPoGStep] {
        guard watchAskedBeforeThereWasAnAnswer else {
            return askingIfNeeded ? [.askForReset] : []
        }
        watchAskedBeforeThereWasAnAnswer = false
        _ = claimResetComplete()
        return [.answerReset]
    }

    /// What a packet the watch has sent asks of the link, in the order it has to
    /// happen.
    ///
    /// Here rather than in the delegate for the same reason as everything else
    /// in this type: the delegate needs a `CBPeripheral` to do any of it, and a
    /// `CBPeripheral` is not something a test can make. The two mid-session
    /// resets in particular had no other way of being walked through — they are
    /// what the watch sends when its acknowledgement timeouts have run out,
    /// which is not a thing to wait around for on a real one.
    mutating func steps(for packet: PPoGPacket, hasSession: Bool) -> [PPoGStep] {
        // Nothing, because there is nothing that can be done yet. The watch
        // reaches the phone's own protocol service as a GATT client, so it can
        // talk before this side has discovered anything to answer through: a
        // reset arrived once at 11:52:02 with no `link established` behind it,
        // the answer had nowhere to go, and the link was dropped over it. The
        // watch asks again, so leaving it alone costs one round trip and
        // dropping it cost the whole connect.
        //
        // Every other packet yields at least one step, so an empty answer means
        // this and only this.
        guard mayStartProtocol else {
            // Left alone, but not forgotten: the watch is now waiting for an
            // answer, and `stepsToOpenTheSession(askingIfNeeded:)` is where it
            // gets one.
            if case .resetRequest = packet { watchAskedBeforeThereWasAnAnswer = true }
            return []
        }

        switch packet {
        case .resetRequest:
            var steps: [PPoGStep] = []
            if hasSession {
                // The watch wants the transport reopened, not the link dropped.
                steps.append(.startSessionOver(because: "the watch asked for a new one"))
                // And the handshake that follows owes a ResetComplete again.
                forgetResetComplete()
            }
            _ = claimResetComplete()
            steps.append(.answerReset)
            return steps

        case .resetComplete(_, let receiveWindow, let transmitWindow):
            if hasSession {
                // A ResetComplete with no request of ours behind it: the watch
                // has decided the session is new and this one is not, so it goes
                // and the handshake is opened again from this side.
                forgetResetComplete()
                return [
                    .startSessionOver(because: "the watch answered a reset nobody asked for"),
                    .askForReset,
                ]
            }
            var steps: [PPoGStep] = []
            // Only the side that opened the handshake still owes one. A second
            // reads to the watch as a request to tear the session down again.
            if claimResetComplete() {
                steps.append(.answerReset)
            }
            steps.append(.openSession(
                watchReceiveWindow: receiveWindow,
                watchTransmitWindow: transmitWindow
            ))
            return steps

        case .data, .acknowledgement:
            return [.giveToSession]
        }
    }
}

/// One thing to do about a packet the watch has sent.
enum PPoGStep: Equatable {
    /// Give up the session, keep the link that carries it, and say why.
    case startSessionOver(because: String)
    /// Answer the watch's reset.
    case answerReset
    /// Ask the watch to start a session.
    case askForReset
    /// Open the session on the windows the watch offered.
    case openSession(watchReceiveWindow: UInt8, watchTransmitWindow: UInt8)
    /// Hand the packet to the session that is open, if one is.
    case giveToSession
}
