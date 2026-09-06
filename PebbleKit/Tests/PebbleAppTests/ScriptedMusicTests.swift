#if os(macOS)
import Foundation
import Testing
@testable import PebbleApp
@testable import PebbleProtocol

/// Reading Music's answers, and what the watch is told about them.
@Suite
@MainActor
struct ScriptedMusicTests {
    /// Verbatim from Music on macOS 27, tabs and all.
    private static let playing =
        "playing\tTell Me What It Is\tTyler, The Creator\tDON'T TAP THE GLASS\t202.180999755859\t52.242000579834\t100\tfalse\toff\t0\t0"
    private static let stopped = "stopped\t\t\t\t0\t0\t100\tfalse\toff\t0\t0"

    @Test
    func aPlayingTrackIsReadFieldForField() throws {
        let snapshot = try #require(MusicScript.snapshot(from: Self.playing))

        #expect(snapshot.nowPlaying.title == "Tell Me What It Is")
        #expect(snapshot.nowPlaying.artist == "Tyler, The Creator")
        #expect(snapshot.nowPlaying.album == "DON'T TAP THE GLASS")
        #expect(snapshot.playback.state == .playing)
        // Music counts in seconds and the watch in milliseconds.
        #expect(snapshot.nowPlaying.durationMilliseconds == 202_180)
        #expect(snapshot.playback.positionMilliseconds == 52_242)
        #expect(snapshot.volumePercent == 100)
        #expect(snapshot.playback.shuffle == .off)
        #expect(snapshot.playback.repeatState == .off)
        // A streamed track has neither, and zero is not a track number.
        #expect(snapshot.nowPlaying.trackNumber == nil)
        #expect(snapshot.nowPlaying.trackCount == nil)
    }

    @Test
    func aStoppedPlayerReadsAsPausedWithNothingPlaying() throws {
        let snapshot = try #require(MusicScript.snapshot(from: Self.stopped))

        // The watch has no "stopped": it draws a player that is not playing.
        #expect(snapshot.playback.state == .paused)
        #expect(snapshot.nowPlaying.title.isEmpty)
        #expect(snapshot.nowPlaying.durationMilliseconds == nil)
        #expect(snapshot.playback.playRatePercent == 0)
    }

    @Test
    func ananswerThatIsNotOneIsRefusedRatherThanGuessedAt() {
        #expect(MusicScript.snapshot(from: "") == nil)
        #expect(MusicScript.snapshot(from: "playing\tTitle") == nil)
    }

    @Test
    func theSourceHoldsWhatItLastReadAndSaysWhenItChanges() async throws {
        // Whether Music is open is said here rather than read off the machine:
        // taken from `NSRunningApplication`, this counted the reader's own
        // Music window and answered `changes == 3` under a full suite (#79).
        let changes = ChangeLog()
        let source = ScriptedMusicSource(
            runner: ScriptedAnswers(Self.playing),
            interval: .milliseconds(10),
            isRunning: { true }
        )
        source.onChange = { changes.note() }

        source.start()
        await changes.reach(1)
        #expect(source.snapshot?.nowPlaying.title == "Tell Me What It Is")

        // Reading the same thing again is not news. Waited out rather than
        // woken, because what is claimed is that nothing happens — and a busy
        // machine can only make that more true, never less.
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 1)

        source.stop()
        #expect(source.snapshot == nil)
    }

    /// Music closing is news, and the snapshot goes with it.
    ///
    /// This is the branch that made #79 read as three changes: it puts the
    /// snapshot back to nil and says so, which is right — the point is that a
    /// test decides when it happens.
    @Test
    func aClosedMusicIsForgottenAndSaidOnce() async throws {
        let open = Mutable(true)
        let changes = ChangeLog()
        let source = ScriptedMusicSource(
            runner: ScriptedAnswers(Self.playing),
            interval: .milliseconds(10),
            isRunning: { open.value }
        )
        source.onChange = { changes.note() }

        source.start()
        await changes.reach(1)
        #expect(source.snapshot != nil)

        open.value = false
        await changes.reach(2)
        #expect(source.snapshot == nil)

        // Still closed is not news again.
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.count == 2)

        source.stop()
    }

    @Test
    func everyActionAsksMusicForSomething() {
        for action in [
            MusicAction.play, .pause, .playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown,
        ] {
            let script = MusicScript.command(for: action)
            #expect(script.hasPrefix("tell application \"Music\""))
            #expect(script.hasSuffix("end tell"))
        }
        // Music refuses `set sound volume to (sound volume)`, so the value has
        // to go through a variable.
        #expect(MusicScript.command(for: .volumeUp).contains("set v to sound volume"))
    }
}

/// A runner that answers with whatever it was given.
/// How often the source said something changed, and a way to wait for the
/// next one.
///
/// Woken by the thing it is waiting for rather than counting `Task.yield()`s:
/// yielding offers another task a chance and does not make it take one, so a
/// count of yields says nothing about whether a 10 ms poll has run. Waiting
/// with no timeout of its own is deliberate — a change that never comes should
/// be bounded by the suite's deadline, which names what it was waiting for.
@MainActor
private final class ChangeLog {
    private(set) var count = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func note() {
        count += 1
        let resuming = waiting
        waiting = []
        for continuation in resuming { continuation.resume() }
    }

    func reach(_ target: Int) async {
        while count < target {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
    }
}

/// A value a closure can be handed and a test can change afterwards.
@MainActor
private final class Mutable<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class ScriptedAnswers: MusicScriptRunner {
    private let answer: String

    init(_ answer: String) {
        self.answer = answer
    }

    func run(_ script: String) async throws -> String? {
        script == MusicScript.read ? answer : nil
    }
}
#endif
