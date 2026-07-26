import Foundation
import MediaPlayer

/// Publishes the loaded song to the lock screen and Control Center, and routes
/// headphone-remote transport commands back to the player.
///
/// The system extrapolates elapsed time from the last published position and
/// playback rate, so this only needs updating when playback state actually
/// changes — not on every tick.
@MainActor
final class NowPlayingController {
    /// What the lock screen shows. Times are source-song seconds, and `rate`
    /// is the practice playback rate so the system clock runs at the speed the
    /// user is actually hearing.
    struct Snapshot: Equatable, Sendable {
        var title: String
        var duration: TimeInterval
        var position: TimeInterval
        var rate: Float
        var isPlaying: Bool
    }

    static let skipInterval: TimeInterval = 5

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var onSkipBackward: ((TimeInterval) -> Void)?

    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var isAcceptingCommands = false
    private var lastSnapshot: Snapshot?

    init() {
        registerHandlers()
        setCommandsEnabled(false)
    }

    /// Enables the remote commands. Recording keeps them off: a headphone
    /// click must not pause the backing track mid-take.
    func setCommandsEnabled(_ enabled: Bool) {
        isAcceptingCommands = enabled
        commandCenter.playCommand.isEnabled = enabled
        commandCenter.pauseCommand.isEnabled = enabled
        commandCenter.togglePlayPauseCommand.isEnabled = enabled
        commandCenter.changePlaybackPositionCommand.isEnabled = enabled
        commandCenter.skipBackwardCommand.isEnabled = enabled
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
    }

    func update(_ snapshot: Snapshot) {
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title.isEmpty ? "Atarang" : snapshot.title,
            // The simulator's lock screen renders the scrubber with both times
            // as "--:--" with or without this, but an explicit media type is
            // what the API expects for audio. Confirm the times on a device.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: snapshot.position),
            // Position is in source seconds, which advance at `rate` against
            // the wall clock, so the practice rate is also the rate the system
            // should extrapolate the lock-screen timer with.
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? Double(snapshot.rate) : 0,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        info[MPMediaItemPropertyArtist] = "Atarang"
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
        #if DEBUG
        print(
            "ATARANG-DIAG nowPlaying published isPlaying=\(snapshot.isPlaying) "
                + "rate=\(snapshot.isPlaying ? snapshot.rate : 0) position=\(Int(snapshot.position))"
        )
        #endif
    }

    func clear() {
        lastSnapshot = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        setCommandsEnabled(false)
    }

    private func registerHandlers() {
        commandCenter.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: Self.skipInterval)
        ]
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.perform { $0.onPlay?() } ?? .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.perform { $0.onPause?() } ?? .commandFailed
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.perform { controller in
                if controller.lastSnapshot?.isPlaying == true {
                    controller.onPause?()
                } else {
                    controller.onPlay?()
                }
            } ?? .commandFailed
        }
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? Self.skipInterval
            return self?.perform { $0.onSkipBackward?(interval) } ?? .commandFailed
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            return self?.perform { $0.onSeek?(event.positionTime) } ?? .commandFailed
        }
    }

    /// Remote command handlers carry no isolation guarantee, but every player
    /// entry point is main-actor isolated. The commands themselves are
    /// disabled when the player cannot accept them, so hopping is safe and the
    /// status can be reported optimistically.
    private nonisolated func perform(
        _ body: @escaping @MainActor @Sendable (NowPlayingController) -> Void
    ) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            guard self.isAcceptingCommands else { return }
            body(self)
        }
        return .success
    }
}
