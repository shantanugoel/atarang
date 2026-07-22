import AVFoundation
import Combine
import Foundation

@MainActor
final class StemPlayer: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var title = ""

    private let engine = AVAudioEngine()
    private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var volumes = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) })
    private var timer: Timer?
    private var startedAt: Date?
    private var startPosition: TimeInterval = 0

    init() {
        for stem in StemKind.allCases {
            let node = AVAudioPlayerNode()
            nodes[stem] = node
            engine.attach(node)
        }
    }

    func load(track: LocalTrack) throws {
        stop(resetPosition: true)
        files = try Dictionary(uniqueKeysWithValues: track.files.map { key, url in
            (key, try AVAudioFile(forReading: url))
        })
        guard files.count == StemKind.allCases.count else { throw PlayerError.incompleteTrack }
        for stem in StemKind.allCases {
            guard let node = nodes[stem], let file = files[stem] else { continue }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        }
        duration = files.values.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
        title = track.title
        isLoaded = duration > 0
        try configureAudioSession()
    }

    func togglePlayback() {
        if isPlaying { pause() } else { try? play() }
    }

    func play() throws {
        guard isLoaded else { return }
        if position >= duration { position = 0 }

        for node in nodes.values { node.stop() }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        let leadTime = 0.08
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTime)
        let startTime = AVAudioTime(hostTime: startHostTime)
        for stem in StemKind.allCases {
            guard let file = files[stem], let node = nodes[stem] else { continue }
            let frame = AVAudioFramePosition(position * file.processingFormat.sampleRate)
            let remaining = max(0, file.length - frame)
            node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil)
            node.volume = volumes[stem] ?? 1
            node.play(at: startTime)
        }

        startPosition = position
        startedAt = Date().addingTimeInterval(leadTime)
        isPlaying = true
        beginTimer()
    }

    func pause() {
        updatePosition()
        for node in nodes.values { node.stop() }
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    func seek(to newPosition: TimeInterval) {
        let shouldResume = isPlaying
        pause()
        position = min(max(0, newPosition), duration)
        if shouldResume { try? play() }
    }

    func setVolume(_ volume: Float, for stem: StemKind) {
        let value = min(max(volume, 0), 1)
        volumes[stem] = value
        nodes[stem]?.volume = value
        objectWillChange.send()
    }

    func volume(for stem: StemKind) -> Float { volumes[stem] ?? 1 }

    func unload() {
        stop(resetPosition: true)
        files.removeAll()
        duration = 0
        title = ""
        isLoaded = false
    }

    private func stop(resetPosition: Bool) {
        for node in nodes.values { node.stop() }
        engine.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        if resetPosition { position = 0 }
    }

    private func beginTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func timerFired() { updatePosition() }

    private func updatePosition() {
        guard isPlaying, let startedAt else { return }
        position = min(duration, startPosition + max(0, Date().timeIntervalSince(startedAt)))
        if position >= duration {
            for node in nodes.values { node.stop() }
            timer?.invalidate()
            timer = nil
            isPlaying = false
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }
}

private enum PlayerError: LocalizedError {
    case incompleteTrack
    var errorDescription: String? { "This track does not contain all four stems." }
}
