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

    /// The handshake, walked through packet by packet.
    ///
    /// Whichever side opens it, exactly one ResetComplete goes out from here.
    @Test
    func aHandshakeAnswersOnceAndThenOpensTheSession() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))

        // The phone asked, so the watch's answer is not one to answer again.
        _ = setup.claimResetComplete()
        #expect(
            setup.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)
                == [.openSession(watchReceiveWindow: 17, watchTransmitWindow: 4)]
        )

        // The other way round: the watch asked first.
        var watchFirst = LinkSetup()
        _ = watchFirst.apply(status(paired: true, encrypted: true))
        #expect(
            watchFirst.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false)
                == [.answerReset]
        )
        #expect(
            watchFirst.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)
                == [.openSession(watchReceiveWindow: 17, watchTransmitWindow: 4)]
        )
    }

    /// A reset that arrives mid-session.
    ///
    /// The watch sends one when its acknowledgement timeouts have run out, and
    /// what it is asking for is the transport reopened. The link used to be
    /// dropped under it, which cost a reconnect, the bond check and several
    /// seconds of handshake — twice in one on-device session, taking a weather
    /// write and a glance with it each time.
    ///
    /// There is no waiting for a real watch to do this, and no `CBPeripheral` a
    /// test can make, so deciding it here is what makes it checkable at all.
    @Test
    func aResetMidSessionStartsTheSessionOverOnTheSameLink() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))
        _ = setup.claimResetComplete()

        let steps = setup.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: true)

        // Given up and answered, in that order, and no word about the link.
        #expect(steps == [.startSessionOver(because: "the watch asked for a new one"), .answerReset])
        // The bond is untouched: the link never went.
        #expect(setup.mayStartProtocol)
        // The watch's own ResetComplete follows, and this side already owes
        // nothing — a second would read as a request to tear it down again.
        #expect(
            setup.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)
                == [.openSession(watchReceiveWindow: 17, watchTransmitWindow: 4)]
        )
    }

    /// A ResetComplete mid-session, with no request of ours behind it.
    @Test
    func aResetCompleteNobodyAskedForOpensTheHandshakeFromThisSide() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))
        _ = setup.claimResetComplete()

        let steps = setup.steps(
            for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4),
            hasSession: true
        )

        // The windows are not taken: this is not a session opening, it is one
        // ending, and the next one is asked for rather than assumed.
        #expect(steps == [
            .startSessionOver(because: "the watch answered a reset nobody asked for"),
            .askForReset,
        ])
        // Having asked, this side owes the answer to the watch's reply.
        #expect(
            setup.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)
                == [.answerReset, .openSession(watchReceiveWindow: 17, watchTransmitWindow: 4)]
        )
    }

    @Test
    func dataAndAcknowledgementsGoStraightToTheSession() {
        var setup = LinkSetup()
        #expect(setup.steps(for: .data(sequence: 3, payload: [0x01]), hasSession: true) == [.giveToSession])
        #expect(setup.steps(for: .acknowledgement(sequence: 3), hasSession: true) == [.giveToSession])
        // Handed over even with no session: what to do about that is the
        // caller's, which drops it.
        #expect(setup.steps(for: .acknowledgement(sequence: 3), hasSession: false) == [.giveToSession])
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
