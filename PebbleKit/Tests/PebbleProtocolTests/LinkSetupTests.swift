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

    /// A packet that arrives before this side can answer it.
    ///
    /// The watch reaches the phone's own protocol service as a GATT client, so
    /// it can send a reset before the phone's discovery has produced anything
    /// to answer through. One did, on the reader's phone: the answer had
    /// nowhere to go, the write threw, and the whole connect was given up over
    /// it — `giving up while handling a packet from the watch`, then a retry
    /// three seconds later that worked.
    @Test
    func aPacketBeforeTheLinkCanAnswerIsLeftAlone() {
        // A link that has discovered nothing: pairing is not known either way.
        var setup = LinkSetup()
        #expect(!setup.mayStartProtocol)

        #expect(setup.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false).isEmpty)
        #expect(setup.steps(for: .acknowledgement(sequence: 0), hasSession: false).isEmpty)
        // Nothing was claimed on the way past, so the handshake that follows
        // still owes its ResetComplete.
        let owed = setup.claimResetComplete()
        #expect(owed)

        // Asked to pair and still waiting: still nothing to answer through.
        var pairing = LinkSetup()
        #expect(pairing.apply(status(paired: false, encrypted: false)) == .askWatchToPair)
        #expect(pairing.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false).isEmpty)

        // Bonded: now it is answered.
        var ready = LinkSetup()
        _ = ready.apply(status(paired: true, encrypted: true))
        #expect(
            ready.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false) == [.answerReset]
        )
    }

    /// The reset that arrived too early, answered once there is a way to.
    ///
    /// Leaving it alone stopped the connect being dropped over it (#71) but not
    /// the wait it costs: the watch is holding out for the answer to its own
    /// request and will not take a fresh one in its place, so both sides go
    /// quiet until its retry timer fires. On the reader's phone that was 1.15
    /// seconds of silence against 26 milliseconds when the phone asked first.
    @Test
    func aResetThatArrivedTooEarlyIsAnsweredRatherThanAskedForAgain() {
        var setup = LinkSetup()

        #expect(setup.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false).isEmpty)
        #expect(setup.watchAskedBeforeThereWasAnAnswer)

        _ = setup.apply(status(paired: true, encrypted: true))

        // Answered, not asked: asking would buy nothing and cost the retry.
        #expect(setup.stepsToOpenTheSession(askingIfNeeded: true) == [.answerReset])
        // And that answer is the one this side owed, so the watch's ResetComplete
        // opens the session rather than drawing a second answer out of us.
        #expect(setup.hasSentResetComplete)
        #expect(
            setup.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)
                == [.openSession(watchReceiveWindow: 17, watchTransmitWindow: 4)]
        )
    }

    /// The request is spent once answered, so a link that opens twice — the
    /// characteristic subscribing after the phone has taken the transport over,
    /// say — does not answer a reset the watch has long since had an answer to.
    @Test
    func aResetIsOnlyAnsweredOnceHoweverOftenTheSessionIsOpened() {
        var setup = LinkSetup()
        _ = setup.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false)
        _ = setup.apply(status(paired: true, encrypted: true))

        #expect(setup.stepsToOpenTheSession(askingIfNeeded: true) == [.answerReset])
        #expect(setup.stepsToOpenTheSession(askingIfNeeded: true) == [.askForReset])
        #expect(!setup.watchAskedBeforeThereWasAnAnswer)
    }

    /// A link the watch has said nothing on.
    ///
    /// Which of the two silences it is depends on the transport: the phone opens
    /// the handshake on the watch's own service, and waits on the one it hosts
    /// itself, where a request from here as well leaves both sides mid-handshake.
    @Test
    func aLinkTheWatchHasNotAskedOnIsOpenedOnlyWhereThatIsThisSidesJob() {
        var reversed = LinkSetup()
        _ = reversed.apply(status(paired: true, encrypted: true))
        #expect(reversed.stepsToOpenTheSession(askingIfNeeded: true) == [.askForReset])

        var forward = LinkSetup()
        _ = forward.apply(status(paired: true, encrypted: true))
        #expect(forward.stepsToOpenTheSession(askingIfNeeded: false).isEmpty)
        // Nothing was claimed by waiting, so the watch's request is still answered.
        #expect(
            forward.steps(for: .resetRequest(sequence: 0, version: .one), hasSession: false) == [.answerReset]
        )
    }

    /// Only a request is worth remembering. The leftovers of the last session
    /// arrive the same way — three did on the reader's phone, alongside one
    /// request — and answering a ResetComplete with a ResetComplete reads to the
    /// watch as a request to tear the session down.
    @Test
    func theLeftoversOfTheLastSessionAreNotMistakenForARequest() {
        var setup = LinkSetup()

        _ = setup.steps(for: .data(sequence: 3, payload: [0x01]), hasSession: false)
        _ = setup.steps(for: .acknowledgement(sequence: 3), hasSession: false)
        _ = setup.steps(for: .resetComplete(sequence: 0, receiveWindow: 17, transmitWindow: 4), hasSession: false)

        #expect(!setup.watchAskedBeforeThereWasAnAnswer)
        #expect(setup.stepsToOpenTheSession(askingIfNeeded: true) == [.askForReset])
    }

    @Test
    func dataAndAcknowledgementsGoStraightToTheSession() {
        var setup = LinkSetup()
        _ = setup.apply(status(paired: true, encrypted: true))
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
