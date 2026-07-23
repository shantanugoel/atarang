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
    @Published private(set) var separationModel: SeparationModelKind = .htdemucs
    @Published private(set) var activeStems: [StemKind] = []
    @Published private(set) var recordedTake: RecordedTake?
    @Published private(set) var shareURL: URL?
    @Published var recordingMicrophoneLevel: Float {
        didSet {
            UserDefaults.standard.set(
                recordingMicrophoneLevel,
                forKey: Self.microphoneLevelDefaultsKey
            )
        }
    }
    @Published var recordingBackingLevel: Float {
        didSet {
            UserDefaults.standard.set(
                recordingBackingLevel,
                forKey: Self.backingLevelDefaultsKey
            )
        }
    }
    @Published private(set) var microphoneMeterLevel: Float = 0
    @Published private(set) var isEchoCancellationActive = false
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
    private var recordingID: UUID?
    private var currentTrackID: UUID?
    private var recordingStartedAt: Date?
    private var activeRecordingMicrophoneLevel: Float = 1
    private var activeRecordingBackingLevel: Float = 0.7
    private var interruptionShouldResume = false
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Audio")
    private static let microphoneLevelDefaultsKey = "recordingMicrophoneLevel"
    private static let backingLevelDefaultsKey = "recordingBackingLevel"

    init() {
        let defaults = UserDefaults.standard
        recordingMicrophoneLevel = defaults.object(
            forKey: Self.microphoneLevelDefaultsKey
        ) == nil ? 1 : defaults.float(forKey: Self.microphoneLevelDefaultsKey)
        recordingBackingLevel = defaults.object(
            forKey: Self.backingLevelDefaultsKey
        ) == nil ? 0.7 : defaults.float(forKey: Self.backingLevelDefaultsKey)
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
        stop(resetPosition: true, releaseSession: true)
        files = try Dictionary(uniqueKeysWithValues: track.files.map { key, url in
            (key, try AVAudioFile(forReading: url))
        })
        let expectedStems = Set(track.separationModel.stems)
        guard !files.isEmpty, Set(files.keys) == expectedStems else { throw PlayerError.incompleteTrack }
        activeStems = track.separationModel.stems
        for stem in activeStems {
            guard let node = nodes[stem], let file = files[stem] else { continue }
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
        }
        duration = files.values.map { Double($0.length) / $0.processingFormat.sampleRate }.min() ?? 0
        title = track.title
        separationModel = track.separationModel
        currentTrackID = track.id
        isLoaded = duration > 0
        recordedTake = nil
        shareURL = nil
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
        // Recording has already activated a play-and-record session. Switching
        // back to `.playback` here would silently drop microphone input just as
        // the take begins.
        if !isRecording {
            try configurePlaybackSession()
        }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                // Resetting an engine after installing recording taps can leave
                // a take running without a dependable microphone tap. Fail the
                // recording cleanly instead; the caller tears down the session
                // and lets the user retry.
                if isRecording { throw error }

                // A previous recorder/preview can leave AVFAudio render
                // resources stale even after the session category changes.
                // Resetting and retrying rebuilds the output unit against the
                // now-active playback session.
                engine.stop()
                engine.reset()
                engine.prepare()
                try engine.start()
            }
        }

        let leadTime = 0.08
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTime)
        let startTime = AVAudioTime(hostTime: startHostTime)
        for stem in activeStems {
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

    /// Releases the audio engine while preserving the current playhead.
    ///
    /// History previews use a separate player. Merely pausing the stem nodes
    /// leaves this engine's output unit active, which can make the shared audio
    /// session fail when the preview player takes over.
    func suspend() {
        guard !isRecording else { return }
        updatePosition()
        stop(resetPosition: false, releaseSession: true)
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
        stop(resetPosition: true, releaseSession: true)
        files.removeAll()
        duration = 0
        title = ""
        separationModel = .htdemucs
        activeStems = []
        currentTrackID = nil
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

        let recording = try recordingFolder()
        let folder = recording.folder
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

        let takeID = recording.id
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: microphoneFormat) { [weak self] buffer, _ in
            do { try micFile.write(from: buffer) }
            catch { print("Atarang microphone write failed: \(error)") }
            let level = Self.meterLevel(for: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == takeID, self.isRecording else { return }
                self.microphoneMeterLevel = level
            }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: backingFormat) { buffer, _ in
            do { try mixFile.write(from: buffer) }
            catch { print("Atarang backing write failed: \(error)") }
        }

        microphoneFile = micFile
        backingFile = mixFile
        microphoneURL = micURL
        backingURL = mixURL
        recordingID = recording.id
        recordingStartedAt = Date()
        activeRecordingMicrophoneLevel = recordingMicrophoneLevel
        activeRecordingBackingLevel = recordingBackingLevel
        recordingDuration = 0
        microphoneMeterLevel = 0
        recordedTake = nil
        shareURL = nil
        isRecording = true

        do { try play() }
        catch {
            engine.stop()
            removeRecordingTaps()
            engine.reset()
            isRecording = false
            deactivateAudioSession()
            throw PlayerError.audioSetup("Could not start the audio engine", error)
        }
        logger.info("Performance recording started")
    }

    private nonisolated static func meterLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumOfSquares: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = samples[frameIndex]
                sumOfSquares += sample * sample
            }
        }
        let sampleCount = Float(frameCount * channelCount)
        let rms = sqrt(sumOfSquares / sampleCount)
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let recordingStartedAt {
            recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        if isPlaying, let startedAt {
            position = min(duration, startPosition + max(0, Date().timeIntervalSince(startedAt)))
        }
        isRecording = false

        // Stop every render and input resource before removing the taps. This
        // both stops the backing track at the end of a take and releases the
        // microphone route so iOS can dismiss its recording indicator.
        playbackGeneration += 1
        for node in nodes.values { node.stop() }
        engine.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        removeRecordingTaps()
        engine.reset()
        deactivateAudioSession()
        microphoneMeterLevel = 0
        isEchoCancellationActive = false

        guard let microphoneURL, let backingURL, let recordingID else { return }
        let measuredDuration = min(
            audioDuration(at: microphoneURL),
            audioDuration(at: backingURL)
        )
        recordingDuration = measuredDuration
        let take = RecordedTake(
            id: recordingID,
            title: title,
            microphoneURL: microphoneURL,
            backingURL: backingURL,
            microphoneLevel: activeRecordingMicrophoneLevel,
            backingLevel: activeRecordingBackingLevel,
            duration: measuredDuration,
            createdAt: Date()
        )
        recordedTake = take
        let metadata = RecordingMetadata(
            id: take.id,
            title: take.title,
            createdAt: take.createdAt,
            duration: take.duration,
            sourceTrackID: currentTrackID,
            microphoneLevel: take.microphoneLevel,
            backingLevel: take.backingLevel,
            exportedFilename: nil
        )
        do {
            try LibraryMetadata.write(
                metadata,
                to: microphoneURL.deletingLastPathComponent()
                    .appendingPathComponent(LibraryMetadata.recordingFilename)
            )
            NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        } catch {
            logger.error("Could not save recording metadata: \(error.localizedDescription, privacy: .public)")
        }
        logger.info("Performance recording stopped after \(measuredDuration, privacy: .public) seconds")
        export(take, sourceTrackID: currentTrackID)
    }

    private func removeRecordingTaps() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        microphoneFile = nil
        backingFile = nil
        recordingStartedAt = nil
    }

    private func export(_ take: RecordedTake, sourceTrackID: UUID?) {
        isExporting = true
        shareURL = nil
        Task {
            do {
                let exportedURL = try await RecordingExporter.export(take: take)
                shareURL = exportedURL
                let metadata = RecordingMetadata(
                    id: take.id,
                    title: take.title,
                    createdAt: take.createdAt,
                    duration: take.duration,
                    sourceTrackID: sourceTrackID,
                    microphoneLevel: take.microphoneLevel,
                    backingLevel: take.backingLevel,
                    exportedFilename: exportedURL.lastPathComponent
                )
                do {
                    try LibraryMetadata.write(
                        metadata,
                        to: take.microphoneURL.deletingLastPathComponent()
                            .appendingPathComponent(LibraryMetadata.recordingFilename)
                    )
                } catch {
                    logger.error("Could not update recording metadata: \(error.localizedDescription, privacy: .public)")
                }
                NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
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

    private func recordingFolder() throws -> (id: UUID, folder: URL) {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Recordings", isDirectory: true)
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder)
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

    private func stop(resetPosition: Bool, releaseSession: Bool = false) {
        playbackGeneration += 1
        for node in nodes.values { node.stop() }
        engine.stop()
        engine.reset()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        if resetPosition { position = 0 }
        if releaseSession { deactivateAudioSession() }
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
        if isRecording {
            stopRecording()
        } else {
            stop(resetPosition: false, releaseSession: true)
        }
    }

    private func updatePosition() {
        if isRecording, let recordingStartedAt {
            recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        guard isPlaying, let startedAt else { return }
        position = min(duration, startPosition + max(0, Date().timeIntervalSince(startedAt)))
        if position >= duration {
            if isRecording {
                stopRecording()
            } else {
                stop(resetPosition: false, releaseSession: true)
            }
        }
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            logger.debug("Audio session was already inactive or busy: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configurePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(.playback, mode: .default)
        }
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
        if #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            // This input path is tuned for capturing a wider range of audio
            // while removing sound played through the built-in speaker. It is
            // a better fit for singing and instruments than voice-chat DSP.
            try session.setPrefersEchoCancelledInput(true)
        }
        try session.setActive(true)
        if #available(iOS 18.2, *) {
            isEchoCancellationActive = session.isEchoCancelledInputEnabled
        } else {
            isEchoCancellationActive = false
        }
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
        case .incompleteTrack: "This track does not contain all of the stems produced by its separation model."
        case .noTrack: "Separate and load a song before recording."
        case .microphoneDenied: "Microphone access is required. Enable Atarang in Settings → Privacy & Security → Microphone."
        case .noMicrophone: "No microphone input is available."
        case .audioSetup(let stage, let error): "\(stage): \(error.localizedDescription)"
        }
    }
}
