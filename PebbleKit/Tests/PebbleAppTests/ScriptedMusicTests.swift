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
        let runner = ScriptedAnswers(Self.playing)
        let source = ScriptedMusicSource(runner: runner, interval: .milliseconds(10))
        var changes = 0
        source.onChange = { changes += 1 }

        source.start()
        for _ in 0..<200 where source.snapshot == nil { await Task.yield() }
        #expect(source.snapshot?.nowPlaying.title == "Tell Me What It Is")
        #expect(changes == 1)

        // Reading the same thing again is not news.
        for _ in 0..<50 { await Task.yield() }
        #expect(changes == 1)

        source.stop()
        #expect(source.snapshot == nil)
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
