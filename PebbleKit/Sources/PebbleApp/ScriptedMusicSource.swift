#if os(macOS)
import AppKit
import Foundation
import PebbleProtocol

/// Something that can ask a scriptable application a question and read the
/// answer back. A protocol so the reading and writing above it can be tested
/// without a Mac that has Music open.
protocol MusicScriptRunner: Sendable {
    /// The script's result as text, or nil where it returned nothing.
    func run(_ script: String) async throws -> String?
}

/// The words this asks Music in, and how to read what comes back.
///
/// Kept together because the order of the fields in the answer is the only
/// thing tying the two halves: a field added to one is nonsense in the other.
enum MusicScript {
    static let bundleID = "com.apple.Music"

    /// One round trip for everything the watch shows. Music answers a stopped
    /// player with no track at all, so those fields come back empty.
    static let read = """
    tell application "Music"
    \tset playing_state to (player state as text)
    \tset the_volume to (sound volume as text)
    \tset is_shuffling to (shuffle enabled as text)
    \tset repeat_mode to (song repeat as text)
    \tif playing_state is "stopped" then
    \t\treturn playing_state & tab & tab & tab & tab & "0" & tab & "0" & tab & the_volume & tab & is_shuffling & tab & repeat_mode & tab & "0" & tab & "0"
    \tend if
    \tset the_track to current track
    \treturn playing_state & tab & (name of the_track) & tab & (artist of the_track) & tab & (album of the_track) & tab & ((duration of the_track) as text) & tab & (player position as text) & tab & the_volume & tab & is_shuffling & tab & repeat_mode & tab & ((track number of the_track) as text) & tab & ((track count of the_track) as text)
    end tell
    """

    /// Music refuses `set sound volume to (sound volume)` — the value has to be
    /// read into a variable first — so stepping the volume is two statements.
    static func command(for action: MusicAction) -> String {
        let body = switch action {
        case .play: "play"
        case .pause: "pause"
        case .playPause: "playpause"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        case .volumeUp: "set v to sound volume\n\tset sound volume to (v + 10)"
        case .volumeDown: "set v to sound volume\n\tset sound volume to (v - 10)"
        }
        return "tell application \"Music\"\n\t\(body)\nend tell"
    }

    static func snapshot(from answer: String) -> MusicSnapshot? {
        let fields = answer.components(separatedBy: "\t")
        guard fields.count >= 11 else { return nil }
        let state: MusicPlaybackState = switch fields[0] {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .paused
        case "fast forwarding": .fastForwarding
        case "rewinding": .rewinding
        default: .unknown
        }
        let seconds = { (text: String) in Double(text) ?? 0 }
        let milliseconds = { (text: String) in UInt32(clamping: Int(seconds(text) * 1000)) }
        let duration = milliseconds(fields[4])
        let count = UInt32(fields[10]).flatMap { $0 == 0 ? nil : $0 }
        let number = UInt32(fields[9]).flatMap { $0 == 0 ? nil : $0 }
        let repeatState: MusicRepeatState = switch fields[8] {
        case "off": .off
        case "one": .one
        case "all": .all
        default: .unknown
        }
        return MusicSnapshot(
            playerPackage: bundleID,
            playerName: String(localized: "Music", bundle: .module),
            nowPlaying: MusicNowPlaying(
                artist: fields[2],
                album: fields[3],
                title: fields[1],
                durationMilliseconds: duration == 0 ? nil : duration,
                trackCount: count,
                trackNumber: number
            ),
            playback: MusicPlaybackStatus(
                state: state,
                positionMilliseconds: milliseconds(fields[5]),
                playRatePercent: state == .playing ? 100 : 0,
                shuffle: fields[7] == "true" ? .on : .off,
                repeatState: repeatState,
                skipSeeksWithinTrack: false
            ),
            volumePercent: UInt8(clamping: Int(seconds(fields[6])))
        )
    }
}

/// What the machine is playing, as far as anything is allowed to see it.
///
/// No public API reads the system's now-playing state on macOS — the one that
/// sounds like it would, `MPNowPlayingInfoCenter`, publishes this app's own
/// state rather than reading anyone else's. What is left is asking a player
/// that has a scripting dictionary, so this sees Music and nothing else: not a
/// browser, not another player, not the system as a whole.
///
/// The answer is kept rather than fetched on demand, because `snapshot` is read
/// synchronously and an Apple Event is a round trip to another process.
@MainActor
final class ScriptedMusicSource: SystemMusicSource {
    var onChange: (() -> Void)?
    private(set) var snapshot: MusicSnapshot?

    private let runner: any MusicScriptRunner
    private let interval: Duration
    /// Whether Music is there to be asked.
    ///
    /// Injected for the same reason `WatchPull` and `PendingReply` take their
    /// sleeps and `MusicCoordinator` takes its debounce: read straight from
    /// `NSRunningApplication`, this made the tests measure whether the reader
    /// happened to have Music open. One answered `changes == 3` where the
    /// script it was given never changed, because a moment of "not running"
    /// puts the snapshot back to nil and says so.
    private let isRunning: @MainActor () -> Bool
    private var watching: Task<Void, Never>?
    /// Whether the last script was refused, so a refusal is said once rather
    /// than every two seconds — and said again if it comes back after working.
    private var wasRefused = false

    init(
        runner: any MusicScriptRunner,
        interval: Duration = .seconds(2),
        isRunning: @escaping @MainActor () -> Bool = {
            !NSRunningApplication
                .runningApplications(withBundleIdentifier: MusicScript.bundleID)
                .isEmpty
        }
    ) {
        self.runner = runner
        self.interval = interval
        self.isRunning = isRunning
    }

    func start() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(2))
            }
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
        snapshot = nil
    }

    func perform(_ action: MusicAction) {
        guard isMusicRunning else { return }
        Task { [weak self, runner] in
            do {
                _ = try await runner.run(MusicScript.command(for: action))
            } catch {
                await self?.sayItWasRefused(error, doing: "\(action)")
            }
        }
        // The watch expects the change to show; asking again beats waiting for
        // the next turn of the loop.
        Task { [weak self] in await self?.refresh() }
    }

    /// Asked before every script, because `tell application "Music"` launches
    /// Music when it is not running, and polling must not do that.
    private var isMusicRunning: Bool {
        isRunning()
    }

    private func refresh() async {
        guard isMusicRunning else {
            if snapshot != nil {
                snapshot = nil
                onChange?()
            }
            return
        }
        let answer: String?
        do {
            answer = try await runner.run(MusicScript.read)
        } catch {
            await sayItWasRefused(error, doing: "reading what is playing")
            return
        }
        if wasRefused {
            wasRefused = false
            await DiagnosticLog.shared.record(
                category: "music",
                message: "Music is answering again"
            )
        }
        // Stopped while the script ran, which does not stop for being asked
        // to: the answer is for a watch that has gone.
        guard watching != nil else { return }
        guard let answer, let fresh = MusicScript.snapshot(from: answer) else { return }
        guard fresh != snapshot else { return }
        snapshot = fresh
        onChange?()
    }

    /// Said once, not every two seconds.
    ///
    /// Not a `try?`: a refusal swallowed sends the watch a track with no
    /// title — three length-zero strings, four bytes on the wire — which
    /// cannot be told from music that really has stopped. The app claims
    /// `com.apple.security.automation.apple-events`, so the first script
    /// raises the system's automation prompt, and a refusal is the reader's
    /// answer to it: it stands until they change it in System Settings, and
    /// asking again every two seconds changes nothing.
    private func sayItWasRefused(_ error: any Error, doing what: String) async {
        guard !wasRefused else { return }
        wasRefused = true
        await DiagnosticLog.shared.record(
            .error,
            category: "music",
            message: "Music refused \(what): \(String(reflecting: error))"
        )
    }
}

/// Runs a script through `NSAppleScript`, which is neither `Sendable` nor safe
/// to touch from two threads, on one queue of its own.
struct AppleScriptRunner: MusicScriptRunner {
    private static let queue = DispatchQueue(label: "dev.pebble.applescript")

    func run(_ script: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                var error: NSDictionary?
                let value = unsafe NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error {
                    continuation.resume(throwing: MusicScriptError.refused(String(describing: error)))
                } else {
                    continuation.resume(returning: value?.stringValue)
                }
            }
        }
    }
}

enum MusicScriptError: Error {
    /// Automation permission withheld, or Music answered with an error of its own.
    case refused(String)
}
#endif
