import AVFoundation
import Combine
import Foundation
import OSLog

@MainActor
final class StemPlayer: ObservableObject, @unchecked Sendable {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var isExporting = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var title = ""
    @Published private(set) var recordedTake: RecordedTake?
    @Published private(set) var shareURL: URL?
    @Published var alertMessage: String?

    private let engine = AVAudioEngine()
    private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var volumes = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) })
    private var timer: Timer?
    private var startedAt: Date?
    private var startPosition: TimeInterval = 0
    private var playbackGeneration = 0

    private var microphoneFile: AVAudioFile?
    private var backingFile: AVAudioFile?
    private var microphoneURL: URL?
    private var backingURL: URL?
    private var recordingStartedAt: Date?
    private var interruptionShouldResume = false
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Audio")

    init() {
        for stem in StemKind.allCases {
            let node = AVAudioPlayerNode()
            nodes[stem] = node
            engine.attach(node)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func load(track: LocalTrack) throws {
        if isRecording { stopRecording() }
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
        recordedTake = nil
        shareURL = nil
        try configurePlaybackSession()
    }

    func togglePlayback() {
        guard !isRecording else { return }
        if isPlaying { pause() } else {
            do { try play() }
            catch { alertMessage = error.localizedDescription }
        }
    }

    func play() throws {
        guard isLoaded else { return }
        if position >= duration { position = 0 }

        playbackGeneration += 1
        let generation = playbackGeneration
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
            if stem == .vocals {
                node.scheduleSegment(
                    file,
                    startingFrame: frame,
                    frameCount: AVAudioFrameCount(remaining),
                    at: nil,
                    completionCallbackType: .dataPlayedBack
                ) { [self] _ in
                    Task { @MainActor [self] in self.playbackCompleted(generation: generation) }
                }
            } else {
                node.scheduleSegment(
                    file,
                    startingFrame: frame,
                    frameCount: AVAudioFrameCount(remaining),
                    at: nil
                )
            }
            node.volume = volumes[stem] ?? 1
            node.play(at: startTime)
        }

        startPosition = position
        startedAt = Date().addingTimeInterval(leadTime)
        isPlaying = true
        beginTimer()
    }

    func pause() {
        guard !isRecording else { return }
        pausePlayback()
    }

    func seek(to newPosition: TimeInterval) {
        guard !isRecording else { return }
        let shouldResume = isPlaying
        pausePlayback()
        position = min(max(0, newPosition), duration)
        if shouldResume { try? play() }
    }

    func toggleRecording() async {
        if isRecording {
            stopRecording()
            return
        }
        alertMessage = nil
        do {
            try await startRecording()
            alertMessage = nil
        }
        catch {
            alertMessage = error.localizedDescription
            logger.error("Could not start recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setVolume(_ volume: Float, for stem: StemKind) {
        let value = min(max(volume, 0), 1)
        volumes[stem] = value
        nodes[stem]?.volume = value
        objectWillChange.send()
    }

    func volume(for stem: StemKind) -> Float { volumes[stem] ?? 1 }

    func unload() {
        if isRecording { stopRecording() }
        stop(resetPosition: true)
        files.removeAll()
        duration = 0
        title = ""
        isLoaded = false
        recordedTake = nil
        shareURL = nil
    }

    private func startRecording() async throws {
        guard isLoaded else { throw PlayerError.noTrack }
        guard await microphonePermissionGranted() else { throw PlayerError.microphoneDenied }

        let resumePosition = position
        pausePlayback()
        engine.stop()
        position = resumePosition
        do { try configureRecordingSession() }
        catch { throw PlayerError.audioSetup("Could not activate microphone mode", error) }

        let folder = try recordingFolder()
        let micURL = folder.appendingPathComponent("microphone.caf")
        let mixURL = folder.appendingPathComponent("backing.caf")
        let inputNode = engine.inputNode
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        let backingFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0, backingFormat.sampleRate > 0 else {
            throw PlayerError.noMicrophone
        }

        let micFile: AVAudioFile
        let mixFile: AVAudioFile
        do {
            micFile = try AVAudioFile(
                forWriting: micURL,
                settings: microphoneFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            mixFile = try AVAudioFile(
                forWriting: mixURL,
                settings: backingFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw PlayerError.audioSetup("Could not create recording files", error)
        }

        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: microphoneFormat) { buffer, _ in
            do { try micFile.write(from: buffer) }
            catch { print("Atarang microphone write failed: \(error)") }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: backingFormat) { buffer, _ in
            do { try mixFile.write(from: buffer) }
            catch { print("Atarang backing write failed: \(error)") }
        }

        microphoneFile = micFile
        backingFile = mixFile
        microphoneURL = micURL
        backingURL = mixURL
        recordingStartedAt = Date()
        recordingDuration = 0
        recordedTake = nil
        shareURL = nil
        isRecording = true

        do { try play() }
        catch {
            removeRecordingTaps()
            isRecording = false
            throw PlayerError.audioSetup("Could not start the audio engine", error)
        }
        logger.info("Performance recording started")
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        updatePosition()
        removeRecordingTaps()

        guard let microphoneURL, let backingURL else { return }
        let measuredDuration = min(
            audioDuration(at: microphoneURL),
            audioDuration(at: backingURL)
        )
        recordingDuration = measuredDuration
        let take = RecordedTake(
            id: UUID(),
            title: title,
            microphoneURL: microphoneURL,
            backingURL: backingURL,
            duration: measuredDuration,
            createdAt: Date()
        )
        recordedTake = take
        logger.info("Performance recording stopped after \(measuredDuration, privacy: .public) seconds")
        export(take)
    }

    private func removeRecordingTaps() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        microphoneFile = nil
        backingFile = nil
        recordingStartedAt = nil
    }

    private func export(_ take: RecordedTake) {
        isExporting = true
        shareURL = nil
        Task {
            do {
                shareURL = try await RecordingExporter.export(take: take)
                logger.info("Shareable M4A export finished")
            } catch {
                alertMessage = error.localizedDescription
                logger.error("M4A export failed: \(error.localizedDescription, privacy: .public)")
            }
            isExporting = false
        }
    }

    private func microphonePermissionGranted() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    private func recordingFolder() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recordings", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func audioDuration(at url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func pausePlayback() {
        updatePosition()
        playbackGeneration += 1
        for node in nodes.values { node.stop() }
        timer?.invalidate()
        timer = nil
        isPlaying = false
    }

    private func stop(resetPosition: Bool) {
        playbackGeneration += 1
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

    private func playbackCompleted(generation: Int) {
        guard generation == playbackGeneration, isPlaying else { return }
        position = duration
        isPlaying = false
        timer?.invalidate()
        timer = nil
        if isRecording { stopRecording() }
    }

    private func updatePosition() {
        if isRecording, let recordingStartedAt {
            recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        guard isPlaying, let startedAt else { return }
        position = min(duration, startPosition + max(0, Date().timeIntervalSince(startedAt)))
        if position >= duration {
            for node in nodes.values { node.stop() }
            timer?.invalidate()
            timer = nil
            isPlaying = false
            if isRecording { stopRecording() }
        }
    }

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func configureRecordingSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            interruptionShouldResume = isPlaying
            if isRecording { stopRecording() }
            pausePlayback()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if interruptionShouldResume, options.contains(.shouldResume) {
                try? configurePlaybackSession()
                try? play()
            }
            interruptionShouldResume = false
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else { return }
        if isRecording { stopRecording() }
        pausePlayback()
    }
}

private enum PlayerError: LocalizedError {
    case incompleteTrack
    case noTrack
    case microphoneDenied
    case noMicrophone
    case audioSetup(String, Error)

    var errorDescription: String? {
        switch self {
        case .incompleteTrack: "This track does not contain all four stems."
        case .noTrack: "Separate and load a song before recording."
        case .microphoneDenied: "Microphone access is required. Enable Atarang in Settings → Privacy & Security → Microphone."
        case .noMicrophone: "No microphone input is available."
        case .audioSetup(let stage, let error): "\(stage): \(error.localizedDescription)"
        }
    }
}
