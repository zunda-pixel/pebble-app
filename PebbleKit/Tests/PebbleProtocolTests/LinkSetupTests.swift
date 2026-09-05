import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// Where a link stands between connecting and having a session: bonded or not,
/// and which side is hosting the transport.
@Suite
struct LinkSetupTests {
    private func status(paired: Bool, encrypted: Bool) -> PebbleConnectivityStatus {
        var flags: UInt8 = 0b1
        if paired { flags |= 0b10 }
        if encrypted { flags |= 0b100 }
        return PebbleConnectivityStatus(decoding: [flags, 0, 0, 0])!
    }

    @Test
    func aBondedWatchIsReadyWithoutBeingAsked() {
        var setup = LinkSetup()

        #expect(setup.apply(status(paired: true, encrypted: true)) == .ready(wasPairing: false))
        #expect(setup.mayStartProtocol)
        // A second report changes nothing: the protocol has already started.
        #expect(setup.apply(status(paired: true, encrypted: true)) == .wait)
    }

    @Test
    func aWatchThatIsNotBondedIsAskedOnceAndThenWaitedFor() {
        var setup = LinkSetup()

        #expect(setup.apply(status(paired: false, encrypted: false)) == .askWatchToPair)
        #expect(!setup.mayStartProtocol)
        // The reader is looking at a prompt; asking again would put up another.
        #expect(setup.apply(status(paired: false, encrypted: false)) == .wait)

        // They accepted, which is the case that needs the rest of the handshake
        // given a fresh deadline of its own.
        #expect(setup.apply(status(paired: true, encrypted: true)) == .ready(wasPairing: true))
        #expect(setup.mayStartProtocol)
    }

    @Test
    func aPairedButUnencryptedLinkIsNotReady() {
        var setup = LinkSetup()

        // The phone forgot the bond: paired as far as the watch knows, and unusable.
        #expect(setup.apply(status(paired: true, encrypted: false)) == .askWatchToPair)
        #expect(!setup.mayStartProtocol)
    }

    @Test
    func aWatchWithNoPairingServiceIsReadyToTalkTo() {
        var setup = LinkSetup()
        setup.noteNoPairingService()

        #expect(setup.mayStartProtocol)
    }

    @Test
    func theTransportIsTakenOverOnceAndHandedBackOnce() {
        var setup = LinkSetup()
        #expect(setup.transport == .reversed)

        let tookOver = setup.hostTransportOnPhone()
        // Twice would register the phone's service for this watch a second time.
        let tookOverAgain = setup.hostTransportOnPhone()
        #expect(tookOver)
        #expect(!tookOverAgain)
        #expect(setup.transport == .forward)

        let handedBack = setup.handTransportBackToWatch()
        let handedBackAgain = setup.handTransportBackToWatch()
        #expect(handedBack)
        #expect(!handedBackAgain)
        #expect(setup.transport == .reversed)
    }

    @Test
    func onlyOneResetCompleteIsOwed() {
        var setup = LinkSetup()

        let owed = setup.claimResetComplete()
        // The watch reads a second one as a request to tear the session down.
        let owedAgain = setup.claimResetComplete()
        #expect(owed)
        #expect(!owedAgain)
    }

    /// A watch that asks for a reset mid-session gets the session started over on
    /// the same link, and that second handshake owes a ResetComplete of its own.
    /// Without this the answer is never sent and the watch waits for a session
    /// that nobody opens.
    @Test
    func aSessionStartedOverOwesAResetCompleteAgain() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))
        _ = setup.claimResetComplete()

        setup.forgetResetComplete()

        // Claimed outside the expectation: `#expect` captures its operand
        // immutably and this is a mutating call.
        let owedAgain = setup.claimResetComplete()
        #expect(owedAgain)
        // The bond is not part of it: the link never went.
        #expect(setup.mayStartProtocol)
    }

    @Test
    func aFreshLinkKeepsNothingFromTheLastOne() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))
        _ = setup.hostTransportOnPhone()
        _ = setup.claimResetComplete()

        setup.reset()

        // Which side hosts the transport is decided per link from the watch's
        // service list, and a ResetComplete belongs to one session.
        #expect(setup == LinkSetup())
        #expect(!setup.mayStartProtocol)
        #expect(setup.transport == .reversed)
        #expect(!setup.hasSentResetComplete)
    }
}
