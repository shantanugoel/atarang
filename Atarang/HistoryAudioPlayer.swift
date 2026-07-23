import AVFoundation
import Combine
import Foundation

@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: UUID?
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?

    func toggle(id: UUID, url: URL) {
        if playingID == id, isPlaying {
            pause()
            return
        }
        stop()
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay() else { throw PlaybackError.couldNotPrepare }
            guard player.play() else { throw PlaybackError.couldNotStart }
            self.player = player
            playingID = id
            isPlaying = true
        } catch {
            errorMessage = "This recording could not be played: \(error.localizedDescription)"
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playingID = nil
        isPlaying = false
    }
}

private enum PlaybackError: LocalizedError {
    case couldNotPrepare
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotPrepare: "The recording could not be prepared for playback."
        case .couldNotStart: "Audio playback did not start."
        }
    }
}
