import Foundation
import Testing
@testable import PebbleProtocol
@testable import PebbleTransport

/// Which watch is being chased after a drop, and how long the wait has grown to.
@Suite
@MainActor
struct ReconnectPolicyTests {
    private var watch: WatchConnectionTarget {
        WatchConnectionTarget(id: WatchID("watch"), name: "Pebble 5209", model: .pebbleTime2)
    }

    @Test
    func theWaitGrowsWithEachAttemptAndStartsOverOnceAWatchIsFollowed() {
        let policy = ReconnectPolicy()
        policy.follow(watch)

        let first = policy.schedule {}
        let second = policy.schedule {}
        #expect(second > first)

        // A link that came up puts the wait back to its shortest: the next drop
        // is a new event, not a continuation of the last one's bad luck.
        policy.follow(watch)
        #expect(policy.schedule {} == first)
        policy.cancelSchedule()
    }

    @Test
    func stoppingCancelsTheAttemptItHadQueued() async throws {
        let policy = ReconnectPolicy()
        policy.follow(watch)
        var attempts = 0
        policy.schedule { attempts += 1 }

        // A disconnect the reader asked for. The queued attempt would otherwise
        // undo it a moment later.
        policy.stop()
        try await Task.sleep(for: .milliseconds(80))

        #expect(attempts == 0)
        #expect(policy.watch == nil)
        #expect(!policy.isAutomatic)
    }

    @Test
    func aDisconnectThatWasAskedForIsOnlyForgivenOnce() {
        let policy = ReconnectPolicy()
        policy.expectDisconnect(of: WatchID("watch"))

        #expect(policy.wasExpected(WatchID("watch")))
        // The watch dropping again later is the watch's doing, and worth chasing.
        #expect(!policy.wasExpected(WatchID("watch")))
    }

    @Test
    func chasingStopsOnceEnoughLinksHaveDiedInTheHandshake() {
        // The backoff cannot end this on its own: the connect succeeded every
        // time, so the wait sat at its cap while a watch whose protocol service
        // was unusable went round the loop for six minutes.
        let policy = ReconnectPolicy()
        policy.follow(watch)

        for attempt in 1..<ReconnectPolicy.maximumFailedHandshakes {
            #expect(policy.noteHandshakeFailed(), "gave up on attempt \(attempt)")
        }

        #expect(!policy.noteHandshakeFailed())
        #expect(policy.failedHandshakes == ReconnectPolicy.maximumFailedHandshakes)
    }

    @Test
    func aWatchOutOfRangeNeverUsesUpTheHandshakeBudget() {
        // A connect that no link ever answered is CoreBluetooth waiting for the
        // watch to come back, not a handshake that failed.
        let policy = ReconnectPolicy()
        policy.follow(watch)

        for attempt in 1...(ReconnectPolicy.maximumFailedHandshakes * 4) {
            policy.beginAutomaticAttempt()
            #expect(policy.noteDropBeforeSession(), "gave up on attempt \(attempt)")
        }

        #expect(policy.failedHandshakes == 0)
    }

    @Test
    func onlyLinksThatCameUpAndDiedEndTheChase() {
        let policy = ReconnectPolicy()
        policy.follow(watch)

        for attempt in 1..<ReconnectPolicy.maximumFailedHandshakes {
            policy.beginAutomaticAttempt()
            policy.noteLinkUp()
            #expect(policy.noteDropBeforeSession(), "gave up on attempt \(attempt)")
            // Attempts in between that never reached a link change nothing.
            policy.beginAutomaticAttempt()
            #expect(policy.noteDropBeforeSession())
        }
        policy.beginAutomaticAttempt()
        policy.noteLinkUp()

        #expect(!policy.noteDropBeforeSession())
        #expect(policy.failedHandshakes == ReconnectPolicy.maximumFailedHandshakes)
    }

    @Test
    func oneLinkIsCountedOnceHoweverOftenItIsReportedDropped() {
        let policy = ReconnectPolicy()
        policy.follow(watch)
        policy.beginAutomaticAttempt()
        policy.noteLinkUp()

        _ = policy.noteDropBeforeSession()
        _ = policy.noteDropBeforeSession()

        #expect(policy.failedHandshakes == 1)
    }

    @Test
    func aNewAttemptStartsWithoutALink() {
        let policy = ReconnectPolicy()
        policy.follow(watch)
        policy.beginAutomaticAttempt()
        policy.noteLinkUp()

        policy.beginAutomaticAttempt()

        #expect(!policy.linkCameUp)
        policy.noteLinkUp()
        policy.stop()
        #expect(!policy.linkCameUp)
    }

    @Test
    func aSessionThatOpensForgivesTheFailuresBeforeIt() {
        // A watch that needed four goes and then worked gets the whole budget
        // again the next time it drops, rather than one.
        let policy = ReconnectPolicy()
        policy.follow(watch)
        _ = policy.noteHandshakeFailed()
        _ = policy.noteHandshakeFailed()

        policy.follow(watch)

        #expect(policy.failedHandshakes == 0)
    }

    @Test
    func nothingIsFollowedUntilAWatchIsConnected() {
        let policy = ReconnectPolicy()
        // With no watch to chase, any disconnect is this one's to act on.
        #expect(policy.isFollowingOrIdle(WatchID("anything")))

        policy.follow(watch)
        #expect(policy.isFollowingOrIdle(WatchID("watch")))
        #expect(!policy.isFollowingOrIdle(WatchID("another-watch")))
    }
}
