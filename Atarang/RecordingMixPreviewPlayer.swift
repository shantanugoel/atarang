import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingMixPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private let microphoneNode = AVAudioPlayerNode()
    private let backingNode = AVAudioPlayerNode()
    private let microphoneGain = AVAudioUnitEQ(numberOfBands: 0)
    private var microphoneFile: AVAudioFile?
    private var backingFile: AVAudioFile?
    private var timer: Timer?
    private var startedAt: Date?
    private var startPosition: TimeInterval = 0
    private var playbackGeneration = 0

    init() {
        engine.attach(microphoneNode)
        engine.attach(backingNode)
        engine.attach(microphoneGain)
    }

    func load(recording: HistoryRecording) throws {
        stop()
        guard let microphoneURL = recording.microphoneURL,
              let backingURL = recording.backingURL else {
            throw PreviewError.missingRawAudio
        }
        let microphoneFile = try AVAudioFile(forReading: microphoneURL)
        let backingFile = try AVAudioFile(forReading: backingURL)
        guard microphoneFile.processingFormat.sampleRate > 0,
              backingFile.processingFormat.sampleRate > 0 else {
            throw PreviewError.invalidAudio
        }

        engine.disconnectNodeOutput(microphoneNode)
        engine.disconnectNodeOutput(backingNode)
        engine.disconnectNodeOutput(microphoneGain)
        engine.connect(
            microphoneNode,
            to: microphoneGain,
            format: microphoneFile.processingFormat
        )
        engine.connect(
            microphoneGain,
            to: engine.mainMixerNode,
            format: microphoneFile.processingFormat
        )
        engine.connect(
            backingNode,
            to: engine.mainMixerNode,
            format: backingFile.processingFormat
        )

        self.microphoneFile = microphoneFile
        self.backingFile = backingFile
        duration = min(
            Self.duration(of: microphoneFile),
            Self.duration(of: backingFile)
        )
        position = 0
        engine.prepare()
    }

    func load(take: RecordedTake) throws {
        stop()
        let microphoneFile = try AVAudioFile(forReading: take.microphoneURL)
        let backingFile = try AVAudioFile(forReading: take.backingURL)
        guard microphoneFile.processingFormat.sampleRate > 0,
              backingFile.processingFormat.sampleRate > 0 else {
            throw PreviewError.invalidAudio
        }

        engine.disconnectNodeOutput(microphoneNode)
        engine.disconnectNodeOutput(backingNode)
        engine.disconnectNodeOutput(microphoneGain)
        engine.connect(
            microphoneNode,
            to: microphoneGain,
            format: microphoneFile.processingFormat
        )
        engine.connect(
            microphoneGain,
            to: engine.mainMixerNode,
            format: microphoneFile.processingFormat
        )
        engine.connect(
            backingNode,
            to: engine.mainMixerNode,
            format: backingFile.processingFormat
        )
        self.microphoneFile = microphoneFile
        self.backingFile = backingFile
        duration = min(
            Self.duration(of: microphoneFile),
            Self.duration(of: backingFile)
        )
        position = 0
        setLevels(microphone: take.microphoneLevel, backing: take.backingLevel)
        engine.prepare()
    }

    func setLevels(microphone: Float, backing: Float) {
        let microphone = min(2, max(0, microphone))
        microphoneNode.volume = microphone == 0 ? 0 : 1
        microphoneGain.globalGain = microphone == 0
            ? 0
            : 20 * log10(microphone)
        backingNode.volume = min(1, max(0, backing))
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let microphoneFile, let backingFile, duration > 0 else { return }
        if position >= duration { position = 0 }
        errorMessage = nil
        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try session.setActive(false, options: .notifyOthersOnDeactivation)
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }

            playbackGeneration += 1
            let generation = playbackGeneration
            schedule(
                node: microphoneNode,
                file: microphoneFile,
                from: position
            ) { [weak self] in
                Task { @MainActor in
                    guard let self, self.playbackGeneration == generation else { return }
                    self.finishPlayback()
                }
            }
            schedule(node: backingNode, file: backingFile, from: position)
            microphoneNode.play()
            backingNode.play()
            startPosition = position
            startedAt = Date()
            isPlaying = true
            startTimer()
        } catch {
            errorMessage = "The mix preview could not start: \(error.localizedDescription)"
            stop()
        }
    }

    func pause() {
        updatePosition()
        playbackGeneration += 1
        microphoneNode.stop()
        backingNode.stop()
        timer?.invalidate()
        timer = nil
        startedAt = nil
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        let target = min(duration, max(0, seconds))
        let resume = isPlaying
        playbackGeneration += 1
        microphoneNode.stop()
        backingNode.stop()
        position = target
        startedAt = nil
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if resume { play() }
    }

    func stop(releaseSession: Bool = false) {
        playbackGeneration += 1
        microphoneNode.stop()
        backingNode.stop()
        engine.stop()
        timer?.invalidate()
        timer = nil
        startedAt = nil
        startPosition = 0
        position = 0
        isPlaying = false
        if releaseSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private func schedule(
        node: AVAudioPlayerNode,
        file: AVAudioFile,
        from seconds: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        let sampleRate = file.processingFormat.sampleRate
        let startFrame = min(
            file.length,
            AVAudioFramePosition(seconds * sampleRate)
        )
        let remaining = max(0, file.length - startFrame)
        let requested = AVAudioFramePosition(max(0, duration - seconds) * sampleRate)
        let frameCount = AVAudioFrameCount(min(remaining, requested))
        node.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { _ in completion?() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
    }

    private func updatePosition() {
        guard let startedAt else { return }
        position = min(
            duration,
            startPosition + max(0, Date().timeIntervalSince(startedAt))
        )
    }

    private func finishPlayback() {
        timer?.invalidate()
        timer = nil
        microphoneNode.stop()
        backingNode.stop()
        startedAt = nil
        position = duration
        isPlaying = false
    }

    private static func duration(of file: AVAudioFile) -> TimeInterval {
        Double(file.length) / file.processingFormat.sampleRate
    }
}

private enum PreviewError: LocalizedError {
    case missingRawAudio
    case invalidAudio

    var errorDescription: String? {
        switch self {
        case .missingRawAudio:
            "The original microphone and backing audio are unavailable."
        case .invalidAudio:
            "The original recording audio could not be read."
        }
    }
}
