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
}
