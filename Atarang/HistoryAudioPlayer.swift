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
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
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
    case couldNotStart

    var errorDescription: String? { "Audio playback did not start." }
}
