public import PebbleProtocol
import CoreGraphics
import Foundation
#if os(iOS)
import MediaPlayer
import UIKit
#endif

public struct MusicSnapshot: Equatable, Sendable {
    public var playerPackage: String
    public var playerName: String
    public var nowPlaying: MusicNowPlaying
    public var playback: MusicPlaybackStatus
    public var volumePercent: UInt8
}

@MainActor
protocol SystemMusicSource: AnyObject {
    var onChange: (() -> Void)? { get set }
    var snapshot: MusicSnapshot? { get }
    func start()
    func stop()
    func perform(_ action: MusicAction)
    func artwork(width: Int, height: Int) -> CGImage?
}

extension SystemMusicSource {
    func artwork(width: Int, height: Int) -> CGImage? { nil }
}

@MainActor
final class MusicCoordinator {
    private let send: (PebbleProtocolFrame) async throws -> Void
    private let source: any SystemMusicSource
    private var lastSnapshot: MusicSnapshot?
    private var pushTask: Task<Void, Never>?

    init(
        source: any SystemMusicSource,
        send: @escaping (PebbleProtocolFrame) async throws -> Void
    ) {
        self.source = source
        self.send = send
        source.onChange = { [weak self] in
            self?.schedulePush(force: false)
        }
    }

    func start() {
        source.start()
    }

    func stop() {
        pushTask?.cancel()
        pushTask = nil
        lastSnapshot = nil
        source.stop()
    }

    func watchConnected() {
        schedulePush(force: true)
    }

    func artwork(width: Int, height: Int) -> PebbleEncodedImage? {
        guard let image = source.artwork(width: width, height: height) else { return nil }
        return WatchImageRenderer.encode(image, width: width, height: height)
    }

    func handleFrame(_ frame: PebbleProtocolFrame) {
        guard let message = try? MusicControlCodec.decode(frame) else {
            return
        }
        switch message {
        case .action(let action):
            source.perform(action)
        case .updateRequested:
            schedulePush(force: true)
        }
    }

    private func schedulePush(force: Bool) {
        // Forgetting the last snapshot is the whole of what `force` does, and it has
        // to happen even when a debounced push is already pending: that push would
        // otherwise send a diff to a watch that has just connected.
        if force {
            lastSnapshot = nil
        }
        guard pushTask == nil else {
            return
        }
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.pushTask = nil
            await self.pushChanges()
        }
    }

    private func pushChanges() async {
        let snapshot = source.snapshot ?? MusicSnapshot(
            playerPackage: "",
            playerName: "",
            nowPlaying: MusicNowPlaying(),
            playback: MusicPlaybackStatus(),
            volumePercent: 100
        )
        let previous = lastSnapshot
        lastSnapshot = snapshot
        do {
            if previous?.playerPackage != snapshot.playerPackage || previous?.playerName != snapshot.playerName {
                try await send(MusicControlCodec.playerInfoFrame(
                    package: snapshot.playerPackage,
                    name: snapshot.playerName
                ))
            }
            if previous?.playback != snapshot.playback {
                try await send(MusicControlCodec.playbackStatusFrame(snapshot.playback))
            }
            if previous?.volumePercent != snapshot.volumePercent {
                try await send(MusicControlCodec.volumeFrame(percent: snapshot.volumePercent))
            }
            if previous?.nowPlaying != snapshot.nowPlaying {
                try await send(MusicControlCodec.nowPlayingFrame(snapshot.nowPlaying))
            }
        } catch {
            lastSnapshot = previous
        }
    }
}

#if os(iOS)
@MainActor
final class MediaPlayerMusicSource: SystemMusicSource {
    var onChange: (() -> Void)?
    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [any NSObjectProtocol] = []

    var snapshot: MusicSnapshot? {
        let item = player.nowPlayingItem
        let state: MusicPlaybackState = switch player.playbackState {
        case .playing: .playing
        case .paused, .stopped, .interrupted: .paused
        case .seekingForward: .fastForwarding
        case .seekingBackward: .rewinding
        @unknown default: .unknown
        }
        let nowPlaying = MusicNowPlaying(
            artist: item?.artist ?? "",
            album: item?.albumTitle ?? "",
            title: item?.title ?? "",
            durationMilliseconds: item.map { UInt32(clamping: Int($0.playbackDuration * 1000)) },
            trackCount: item.map { UInt32(clamping: $0.albumTrackCount) },
            trackNumber: item.map { UInt32(clamping: $0.albumTrackNumber) }
        )
        let repeatState: MusicRepeatState = switch player.repeatMode {
        case .none: .off
        case .one: .one
        case .all: .all
        case .default: .unknown
        @unknown default: .unknown
        }
        let shuffle: MusicShuffleState = switch player.shuffleMode {
        case .off: .off
        case .songs, .albums: .on
        case .default: .unknown
        @unknown default: .unknown
        }
        let playback = MusicPlaybackStatus(
            state: state,
            positionMilliseconds: UInt32(clamping: Int(player.currentPlaybackTime * 1000)),
            playRatePercent: state == .playing ? UInt32(clamping: Int(player.currentPlaybackRate * 100)) : 0,
            shuffle: shuffle,
            repeatState: repeatState,
            skipSeeksWithinTrack: false
        )
        return MusicSnapshot(
            playerPackage: "com.apple.Music",
            playerName: "Apple Music",
            nowPlaying: nowPlaying,
            playback: playback,
            volumePercent: 100
        )
    }

    func start() {
        guard observers.isEmpty else {
            return
        }
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [
            Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
            .MPMusicPlayerControllerPlaybackStateDidChange,
        ] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onChange?()
                }
            })
        }
    }

    func stop() {
        guard !observers.isEmpty else {
            return
        }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        player.endGeneratingPlaybackNotifications()
    }

    func artwork(width: Int, height: Int) -> CGImage? {
        guard let artwork = player.nowPlayingItem?.artwork else { return nil }
        // Asking for the size the watch wants lets the store hand back the smallest
        // copy that will do.
        return artwork.image(at: CGSize(width: width, height: height))?.cgImage
    }

    func perform(_ action: MusicAction) {
        switch action {
        case .play:
            player.play()
        case .pause:
            player.pause()
        case .playPause:
            player.playbackState == .playing ? player.pause() : player.play()
        case .nextTrack:
            player.skipToNextItem()
        case .previousTrack:
            player.skipToPreviousItem()
        case .volumeUp, .volumeDown:
            // System volume has no public control API.
            break
        }
    }
}
#endif

/// For a platform with neither a now-playing API nor a player to ask.
@MainActor
final class UnsupportedMusicSource: SystemMusicSource {
    var onChange: (() -> Void)?
    var snapshot: MusicSnapshot? { nil }
    func start() {}
    func stop() {}
    func perform(_ action: MusicAction) {}
}

@MainActor
func makeSystemMusicSource() -> any SystemMusicSource {
    #if os(iOS)
    MediaPlayerMusicSource()
    #elseif os(macOS)
    ScriptedMusicSource(runner: AppleScriptRunner())
    #else
    UnsupportedMusicSource()
    #endif
}
