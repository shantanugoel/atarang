import Accelerate
import AVFoundation
import AudioToolbox
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class StemPlayer {
    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private(set) var playbackState = PlaybackState()
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var title = ""
    private(set) var separationModel: SeparationModelKind = .htdemucs
    private(set) var activeStems: [StemKind] = []
    private(set) var recordedTake: RecordedTake?
    private(set) var practiceSettings = SongPracticeSettings()
    private(set) var countInRemaining = 0
    private(set) var completedRepetitions = 0
    private(set) var isTempoRampHeld = false
    private(set) var isLoopTakeRecording = false

    /// Computed rather than stored so the `UserDefaults` write happens on
    /// assignment. `@Observable` rewrites stored properties into accessors, so
    /// a `didSet` cannot be used; `access` and `withMutation` reproduce the
    /// tracking the macro would otherwise generate.
    var recordingMicrophoneLevel: Float {
        get {
            access(keyPath: \.recordingMicrophoneLevel)
            return storedRecordingMicrophoneLevel
        }
        set {
            withMutation(keyPath: \.recordingMicrophoneLevel) {
                storedRecordingMicrophoneLevel = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.microphoneLevelDefaultsKey)
        }
    }

    var recordingBackingLevel: Float {
        get {
            access(keyPath: \.recordingBackingLevel)
            return storedRecordingBackingLevel
        }
        set {
            withMutation(keyPath: \.recordingBackingLevel) {
                storedRecordingBackingLevel = newValue
            }
            UserDefaults.standard.set(newValue, forKey: Self.backingLevelDefaultsKey)
        }
    }

    private(set) var microphoneMeterLevel: Float = 0
    private(set) var isEchoCancellationActive = false
    private(set) var soloedStem: StemKind?
    private(set) var microphonePermissionDenied = false
    var alertMessage: String?

    @ObservationIgnored private var storedRecordingMicrophoneLevel: Float
    @ObservationIgnored private var storedRecordingBackingLevel: Float

    var position: TimeInterval { playbackState.position }
    var duration: TimeInterval { playbackState.duration }
    var playbackRate: Float { playbackState.rate }
    var pitchSemitones: Float { playbackState.pitchSemitones }
    var loopRange: PlaybackLoopRange? { playbackState.loopRange }
    var isCountingIn: Bool { countInRemaining > 0 }
    var remainingRepetitions: Int {
        guard practiceSettings.repetitionTarget > 0 else { return 0 }
        return max(0, practiceSettings.repetitionTarget - completedRepetitions)
    }

    /// The playhead, computed from the render clock at the moment it is asked
    /// for rather than at the last timer tick.
    ///
    /// This is the display-rate path: a `TimelineView(.animation)` or a
    /// `CADisplayLink` can call it every frame and get a fresh, latency-
    /// compensated value without the player having to publish one. Keep the
    /// callers small — reading it observes `isPlaying` and `playbackState`, so
    /// the view that calls it should be a leaf rather than a whole screen.
    /// `position` remains the timer-rate value for everything else.
    func currentPosition() -> TimeInterval {
        guard isPlaying,
              let node = timingNode(),
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else {
            return playbackState.position
        }
        return playbackState.calculatedPosition(
            renderSampleTime: playerTime.sampleTime,
            sampleRate: playerTime.sampleRate,
            anchorPosition: renderAnchorPosition,
            outputLatency: outputLatency
        )
    }

    private func timingNode() -> AVAudioPlayerNode? {
        guard let stem = activeTimingStem ?? activeStems.first else { return nil }
        return nodes[stem]
    }

    /// Wall-clock seconds elapsed since the current `play()` started, taken
    /// from the metronome node's own timeline.
    ///
    /// It has to come from that node rather than from a stem: clicks are placed
    /// at absolute times in real seconds, while a stem node's frame count is in
    /// *song* seconds, and the two only agree at 1.0×. Reading the stem clock
    /// here made the scheduling window understate how much time had passed
    /// whenever the song was slowed down. The metronome node is connected
    /// straight to the main mixer with no time-pitch unit in front of it, so
    /// its frame count is real time by construction.
    private func currentMetronomeRenderElapsed() -> TimeInterval? {
        guard let renderTime = metronomeNode.lastRenderTime,
              let playerTime = metronomeNode.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0 else { return nil }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    // Audio plumbing and bookkeeping are deliberately untracked: SwiftUI has
    // no business redrawing because a tap-tempo date or a file handle changed.
    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var metronomeNode = AVAudioPlayerNode()
    @ObservationIgnored private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    @ObservationIgnored private var timePitchNodes: [StemKind: AVAudioUnitTimePitch] = [:]
    @ObservationIgnored private var files: [StemKind: AVAudioFile] = [:]
    private var volumes = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) })
    @ObservationIgnored private var lastAudibleVolumes = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) }
    )
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var renderAnchorPosition: TimeInterval = 0
    /// The stem that owns position updates and completions for the pass that
    /// is currently scheduled. See `StemScheduling.timingStem`.
    @ObservationIgnored private var activeTimingStem: StemKind?
    /// Cached because `AVAudioSession` is consulted at display rate.
    @ObservationIgnored private var outputLatency: TimeInterval = 0
    @ObservationIgnored private var clickBuffers: [Bool: AVAudioPCMBuffer] = [:]
    @ObservationIgnored private var metronomePlan = MetronomeClickPlan()
    /// Render seconds queued onto the stems since the last `play()`, which is
    /// also where the next pass's metronome clicks begin.
    @ObservationIgnored private var scheduledRenderDuration: TimeInterval = 0
    @ObservationIgnored private var scrubShouldResume = false
    /// Who asked for the most recent transport change, so a stray pause can be
    /// traced to its origin instead of guessed at.
    @ObservationIgnored private var transportSource = TransportSource.internalLogic

    @ObservationIgnored private var microphoneWriter: AudioTapFileWriter?
    @ObservationIgnored private var backingWriter: AudioTapFileWriter?
    @ObservationIgnored private var microphoneURL: URL?
    @ObservationIgnored private var backingURL: URL?
    /// Where the take being captured is written before it is published. Nothing
    /// discovers a recording from here; `stopRecording` commits it or throws it
    /// away.
    @ObservationIgnored private var recordingStagingFolder: URL?
    /// The first writer failure of the current take, if any. A take that hit
    /// one is never committed.
    @ObservationIgnored private var recordingWriteFailure: Error?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var currentTrackID: UUID?
    @ObservationIgnored private var recordingStartedAt: Date?
    @ObservationIgnored private var activeRecordingMicrophoneLevel: Float = 1
    @ObservationIgnored private var activeRecordingBackingLevel: Float = 0.7
    @ObservationIgnored private var interruptionShouldResume = false
    @ObservationIgnored private var countInTask: Task<Void, Never>?
    @ObservationIgnored private var countInGeneration = 0
    @ObservationIgnored private var practiceThrottle = WriteThrottle(
        interval: StemPlayer.practicePersistenceInterval
    )
    @ObservationIgnored private var practiceFlushTask: Task<Void, Never>?
    @ObservationIgnored private var tapTempoDates: [Date] = []
    @ObservationIgnored private var loopResumeTask: Task<Void, Never>?
    @ObservationIgnored private var playbackRequestID = 0
    @ObservationIgnored private var recordingRouteTransitionDeadline = Date.distantPast
    @ObservationIgnored private let practiceSettingsStore = PracticeSettingsStore()
    @ObservationIgnored private let nowPlaying = NowPlayingController()
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Audio"
    )
    #if DEBUG
    @ObservationIgnored private let diagnostics = PlaybackDiagnostics()
    #endif
    private static let microphoneLevelDefaultsKey = "recordingMicrophoneLevel"
    private static let backingLevelDefaultsKey = "recordingBackingLevel"
    private static let stemLevelDefaultsPrefix = "stemLevels."
    private static let practicePersistenceInterval: TimeInterval = 2
    nonisolated static let metronomeSampleRate = 8_000.0
    /// How far ahead of the render clock metronome clicks are queued. Long
    /// enough that a 30 BPM click never runs the queue dry between timer
    /// ticks, short enough that a setting change is heard promptly.
    private static let metronomeScheduleWindow: TimeInterval = 3

    init() {
        let defaults = UserDefaults.standard
        storedRecordingMicrophoneLevel = defaults.object(
            forKey: Self.microphoneLevelDefaultsKey
        ) == nil ? 1 : defaults.float(forKey: Self.microphoneLevelDefaultsKey)
        storedRecordingBackingLevel = defaults.object(
            forKey: Self.backingLevelDefaultsKey
        ) == nil ? 0.7 : defaults.float(forKey: Self.backingLevelDefaultsKey)
        for stem in StemKind.allCases {
            let node = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            nodes[stem] = node
            timePitchNodes[stem] = timePitch
            engine.attach(node)
            engine.attach(timePitch)
        }
        engine.attach(metronomeNode)
        engine.connect(
            metronomeNode,
            to: engine.mainMixerNode,
            format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.metronomeSampleRate,
                channels: 1,
                interleaved: false
            )
        )
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        clickBuffers = Self.makeClickBuffers()
        configureRemoteCommands()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureRemoteCommands() {
        nowPlaying.onPlay = { [weak self] in
            guard let self, self.isLoaded, !self.isRecording, !self.isPlaying else { return }
            self.togglePlayback(source: .remote)
        }
        nowPlaying.onPause = { [weak self] in
            guard let self, self.isPlaying || self.isCountingIn else { return }
            self.pause(source: .remote)
        }
        nowPlaying.onSeek = { [weak self] position in
            self?.seek(to: position)
        }
        nowPlaying.onSkipBackward = { [weak self] interval in
            self?.skipBackward(seconds: interval)
        }
    }

    /// Republishes what the lock screen and Control Center show. Cheap enough
    /// to call from every transport entry point; the controller drops
    /// duplicates.
    private func publishNowPlaying() {
        guard isLoaded else {
            nowPlaying.clear()
            return
        }
        nowPlaying.setCommandsEnabled(!isRecording)
        nowPlaying.update(
            NowPlayingController.Snapshot(
                title: title,
                duration: duration,
                position: position,
                rate: playbackState.rate,
                isPlaying: isPlaying || isRecording
            )
        )
    }

    func load(track: LocalTrack) throws {
        cancelPendingPlaybackRequest()
        if isRecording { stopRecording() }
        stop(resetPosition: true, releaseSession: true)
        files = try Dictionary(uniqueKeysWithValues: track.files.map { key, url in
            (key, try AVAudioFile(forReading: url))
        })
        let expectedStems = Set(track.separationModel.stems)
        guard !files.isEmpty, Set(files.keys) == expectedStems else { throw PlayerError.incompleteTrack }
        activeStems = track.separationModel.stems
        for stem in activeStems {
            guard let node = nodes[stem],
                  let timePitch = timePitchNodes[stem],
                  let file = files[stem] else { continue }
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(node, to: timePitch, format: file.processingFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        }
        playbackState.load(
            duration: files.values
                .map { Double($0.length) / $0.processingFormat.sampleRate }
                .min() ?? 0
        )
        title = track.title
        separationModel = track.separationModel
        currentTrackID = track.id
        restoreStemLevels(for: track.id)
        practiceSettings = practiceSettingsStore.load(for: track.id)
        practiceSettings.validate(
            duration: playbackState.duration,
            availableStems: activeStems
        )
        playbackState.seek(to: practiceSettings.lastPosition)
        playbackState.setRate(practiceSettings.playbackRate)
        playbackState.setPitchSemitones(practiceSettings.pitchSemitones)
        if practiceSettings.isLoopEnabled,
           let loop = practiceSettings.loopRange {
            _ = playbackState.setLoop(start: loop.start, end: loop.end)
        }
        soloedStem = nil
        applyStemVolumes()
        applyMetronomeLevel()
        isLoaded = playbackState.duration > 0
        recordedTake = nil
        completedRepetitions = 0
        isTempoRampHeld = false
        isLoopTakeRecording = false
        activeTimingStem = activeStems.first
        practiceThrottle.reset()
        publishNowPlaying()
    }

    func togglePlayback(source: TransportSource = .ui) {
        guard !isRecording else { return }
        transportSource = source
        if isPlaying || isCountingIn {
            pause(source: source)
        } else {
            startPlaybackWithCountIn(source: source)
        }
    }

    private func startPlaybackWithCountIn(source: TransportSource) {
        cancelCountIn()
        guard practiceSettings.countInClicks > 0 else {
            requestPlayback(source: source)
            return
        }
        countInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = await self.performCountIn()
            guard completed else { return }
            self.requestPlayback(source: source)
        }
    }

    /// Starts normal playback and retries once after a transient Core Audio I/O
    /// startup failure. Session category changes can briefly leave the hardware
    /// route unavailable even though activation itself succeeded.
    func requestPlayback(source: TransportSource = .ui) {
        transportSource = source
        playbackRequestID += 1
        let requestID = playbackRequestID
        alertMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.play()
                return
            } catch {
                guard Self.isTransientAudioIOStartFailure(error),
                      requestID == self.playbackRequestID,
                      self.isLoaded,
                      !self.isRecording else {
                    self.alertMessage = error.localizedDescription
                    return
                }
                self.logger.warning(
                    "Audio output was not ready; releasing the session before retrying: \(error.localizedDescription, privacy: .public)"
                )
            }

            self.engine.stop()
            self.engine.reset()
            self.deactivateAudioSession()
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard requestID == self.playbackRequestID,
                  self.isLoaded,
                  !self.isRecording else { return }
            do {
                try self.play()
                self.alertMessage = nil
            } catch {
                self.alertMessage = Self.playbackStartupMessage(for: error)
                self.logger.error(
                    "Audio output retry failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func play() throws {
        guard isLoaded else { return }
        if position >= duration { playbackState.seek(to: 0) }
        if let loopRange, (position < loopRange.start || position >= loopRange.end) {
            playbackState.seek(to: loopRange.start)
        }

        let generation = playbackState.beginNewGeneration()
        for node in nodes.values { node.stop() }
        metronomeNode.stop()
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

        applyPlaybackTransform()
        applyMetronomeLevel()
        refreshOutputLatency()
        let leadTime = 0.08
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTime)
        let startTime = AVAudioTime(hostTime: startHostTime)
        renderAnchorPosition = position
        scheduledRenderDuration = 0
        schedulePass(from: position, generation: generation)
        for stem in activeStems {
            nodes[stem]?.volume = effectiveVolume(for: stem)
            nodes[stem]?.play(at: startTime)
        }
        metronomeNode.play(at: startTime)
        isPlaying = true
        beginTimer()
        publishNowPlaying()
        logDiagnosticEvent(
            "play",
            detail: String(format: "position=%.3f source=%@", position, transportSource.rawValue)
        )
    }

    /// The audio the engine is rendering now reaches the speaker one output
    /// latency plus one I/O buffer later. Cached rather than read per frame:
    /// it only changes when the route does.
    private func refreshOutputLatency() {
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        outputLatency = latency.isFinite ? max(0, latency) : 0
    }

    func pause(source: TransportSource = .ui) {
        guard !isRecording else { return }
        cancelPendingPlaybackRequest()
        cancelCountIn()
        pausePlayback(source: source)
    }

    /// Releases the audio engine while preserving the current playhead.
    ///
    /// History previews use a separate player. Merely pausing the stem nodes
    /// leaves this engine's output unit active, which can make the shared audio
    /// session fail when the preview player takes over.
    func suspend() {
        guard !isRecording else { return }
        cancelPendingPlaybackRequest()
        cancelCountIn()
        updatePosition()
        stop(resetPosition: false, releaseSession: true)
        flushPracticeSettings()
    }

    /// Whether a continuous drag — of the playhead or a loop boundary — is in
    /// progress.
    private(set) var isScrubbing = false

    /// Begins a drag: stops the engine **once** and remembers whether to
    /// resume when the finger lifts.
    ///
    /// Without this, every value a `Slider` emits during a drag reached
    /// `seek`, and each one paused, rescheduled, and restarted the whole
    /// engine — around thirty stop/start cycles for one gesture, which is
    /// silent while dragging and clicks audibly on release.
    func beginScrubbing() {
        guard !isRecording, !isScrubbing else { return }
        isScrubbing = true
        scrubShouldResume = isPlaying
        cancelPendingPlaybackRequest()
        cancelCountIn()
        if isPlaying { pausePlayback(source: .scrub) }
    }

    /// Moves the playhead during a drag. Touches media state only — no
    /// scheduling, no engine work.
    func updateScrubPosition(_ newPosition: TimeInterval) {
        guard isScrubbing else {
            seek(to: newPosition)
            return
        }
        playbackState.seek(to: newPosition)
    }

    /// Ends a drag: persists once, republishes once, and resumes once.
    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        let shouldResume = scrubShouldResume
        scrubShouldResume = false
        persistPracticeSettings()
        publishNowPlaying()
        logDiagnosticEvent(
            "scrubEnd",
            detail: String(format: "position=%.3f resume=%@", position, shouldResume ? "yes" : "no")
        )
        if shouldResume { requestPlayback() }
    }

    func seek(to newPosition: TimeInterval) {
        guard !isRecording else { return }
        cancelPendingPlaybackRequest()
        cancelCountIn()
        let shouldResume = isPlaying
        pausePlayback()
        playbackState.seek(to: newPosition)
        persistPracticeSettings()
        publishNowPlaying()
        logDiagnosticEvent("seek", detail: "to=\(String(format: "%.3f", position))")
        if shouldResume { requestPlayback() }
    }

    func skipBackward(seconds: TimeInterval = 5) {
        seek(to: max(0, position - max(0, seconds)))
    }

    /// Changes speed without stopping the music.
    ///
    /// `AVAudioUnitTimePitch.rate` is a live parameter, and since the playhead
    /// is derived from the player node's own frame count — which counts song
    /// frames at any speed — a mid-flight change needs no re-anchoring and no
    /// rescheduling. This used to pause the engine, reschedule every stem, and
    /// start it again, all synchronously on the main actor: audible as a click,
    /// and slow enough on device to leave the speed menu sitting open after the
    /// tap that chose a speed.
    ///
    /// The metronome is the exception. Its clicks are queued ahead on a
    /// wall-clock timeline derived from the old rate, and a player node cannot
    /// unschedule a buffer, so a running click track still needs the pass
    /// restarted to be re-planned at the new tempo.
    func setPlaybackRate(_ rate: Float) {
        guard !isRecording else { return }
        updatePosition()
        let needsMetronomeReplan = isPlaying && practiceSettings.metronomeEnabled
        if needsMetronomeReplan { pausePlayback() }
        playbackState.setRate(rate)
        practiceSettings.playbackRate = playbackState.rate
        persistPracticeSettings()
        applyPlaybackTransform()
        publishNowPlaying()
        if needsMetronomeReplan { requestPlayback() }
    }

    /// Pitch is a live parameter too, and unlike rate it does not affect timing
    /// at all, so nothing needs rescheduling in any case.
    func setPitchSemitones(_ semitones: Float) {
        guard !isRecording else { return }
        updatePosition()
        playbackState.setPitchSemitones(semitones)
        practiceSettings.pitchSemitones = playbackState.pitchSemitones
        persistPracticeSettings()
        applyPlaybackTransform()
    }

    @discardableResult
    func setLoop(start: TimeInterval, end: TimeInterval) -> Bool {
        guard !isRecording else { return false }
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        let accepted = playbackState.setLoop(start: start, end: end)
        if shouldResume { requestPlayback() }
        return accepted
    }

    func clearLoop() {
        guard !isRecording else { return }
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        playbackState.clearLoop()
        practiceSettings.loopStart = nil
        practiceSettings.loopEnd = nil
        practiceSettings.isLoopEnabled = false
        completedRepetitions = 0
        persistPracticeSettings()
        if shouldResume { requestPlayback() }
    }

    func setLoopBoundaryA(at value: TimeInterval? = nil) {
        let start = min(
            max(0, value ?? position),
            max(0, duration - PlaybackLoopRange.minimumDuration)
        )
        let proposedEnd = max(
            practiceSettings.loopEnd ?? 0,
            min(duration, start + max(2, PlaybackLoopRange.minimumDuration))
        )
        updateSavedLoop(start: start, end: proposedEnd)
    }

    func setLoopBoundaryB(at value: TimeInterval? = nil) {
        let end = min(
            duration,
            max(PlaybackLoopRange.minimumDuration, value ?? position)
        )
        let proposedStart = min(
            practiceSettings.loopStart ?? end,
            max(0, end - max(2, PlaybackLoopRange.minimumDuration))
        )
        updateSavedLoop(start: proposedStart, end: end)
    }

    func adjustLoopBoundaryA(by delta: TimeInterval) {
        guard let loop = practiceSettings.loopRange else { return }
        updateSavedLoop(start: loop.start + delta, end: loop.end)
    }

    func adjustLoopBoundaryB(by delta: TimeInterval) {
        guard let loop = practiceSettings.loopRange else { return }
        updateSavedLoop(start: loop.start, end: loop.end + delta)
    }

    func setLoopEnabled(_ enabled: Bool) {
        guard let loop = practiceSettings.loopRange else { return }
        if enabled {
            guard setLoop(start: loop.start, end: loop.end) else { return }
        } else {
            let shouldResume = isPlaying
            if shouldResume { pausePlayback() }
            playbackState.clearLoop()
            if shouldResume { requestPlayback() }
        }
        practiceSettings.isLoopEnabled = enabled
        completedRepetitions = 0
        persistPracticeSettings()
    }

    func setWorkspace(_ workspace: StudioWorkspace) {
        practiceSettings.workspace = workspace
        persistPracticeSettings()
    }

    func setCountInClicks(_ clicks: Int) {
        guard SongPracticeSettings.supportedCountInClicks.contains(clicks) else { return }
        practiceSettings.countInClicks = clicks
        persistPracticeSettings()
    }

    func setMetronomeEnabled(_ enabled: Bool) {
        guard !isRecording else { return }
        practiceSettings.metronomeEnabled = enabled
        persistAndRestartIfPlaying()
    }

    func setMetronomeBPM(_ bpm: Int) {
        guard !isRecording else { return }
        practiceSettings.metronomeBPM = min(
            max(bpm, SongPracticeSettings.supportedBPMRange.lowerBound),
            SongPracticeSettings.supportedBPMRange.upperBound
        )
        persistAndRestartIfPlaying()
    }

    func tapTempo() {
        guard !isRecording else { return }
        let now = Date()
        if let last = tapTempoDates.last, now.timeIntervalSince(last) > 2 {
            tapTempoDates.removeAll()
        }
        tapTempoDates.append(now)
        tapTempoDates = Array(tapTempoDates.suffix(5))
        guard tapTempoDates.count >= 2 else { return }
        let intervals = zip(tapTempoDates.dropFirst(), tapTempoDates).map {
            $0.0.timeIntervalSince($0.1)
        }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        setMetronomeBPM(Int((60 / average).rounded()))
    }

    func setMetronomeSubdivision(_ subdivision: MetronomeSubdivision) {
        guard !isRecording else { return }
        practiceSettings.metronomeSubdivision = subdivision
        persistAndRestartIfPlaying()
    }

    func setMetronomeAccentEnabled(_ enabled: Bool) {
        guard !isRecording else { return }
        practiceSettings.metronomeAccentEnabled = enabled
        persistAndRestartIfPlaying()
    }

    func setMetronomeLevel(_ level: Float) {
        guard !isRecording else { return }
        practiceSettings.metronomeLevel = min(max(level, 0), 1)
        // A node gain, so unlike the other metronome settings this one applies
        // live rather than restarting playback to re-render the click track.
        applyMetronomeLevel()
        persistPracticeSettings()
    }

    func alignMetronome(at position: TimeInterval? = nil) {
        guard !isRecording else { return }
        practiceSettings.metronomeAlignment = min(
            max(0, position ?? self.position),
            duration
        )
        persistAndRestartIfPlaying()
    }

    func setMetronomeOnly(_ enabled: Bool) {
        guard !isRecording else { return }
        practiceSettings.metronomeOnly = enabled
        applyStemVolumes()
        persistPracticeSettings()
    }

    func setRepetitionTarget(_ target: Int) {
        guard !isRecording else { return }
        practiceSettings.repetitionTarget = min(max(0, target), 999)
        completedRepetitions = 0
        persistPracticeSettings()
    }

    func setRepetitionPause(_ seconds: TimeInterval) {
        guard !isRecording else { return }
        practiceSettings.repetitionPause = min(max(0, seconds), 10)
        persistPracticeSettings()
    }

    func configureTempoRamp(
        enabled: Bool? = nil,
        every repetitions: Int? = nil,
        start: Float? = nil,
        increment: Float? = nil,
        target: Float? = nil
    ) {
        guard !isRecording else { return }
        if let enabled { practiceSettings.tempoRampEnabled = enabled }
        if let repetitions {
            practiceSettings.tempoRampEvery = min(max(1, repetitions), 99)
        }
        if let start {
            practiceSettings.tempoRampStart = clampedRate(start)
        }
        if let increment {
            practiceSettings.tempoRampIncrement = min(max(0.01, increment), 0.5)
        }
        if let target {
            practiceSettings.tempoRampTarget = clampedRate(target)
        }
        if practiceSettings.tempoRampStart > practiceSettings.tempoRampTarget {
            practiceSettings.tempoRampStart = practiceSettings.tempoRampTarget
        }
        persistPracticeSettings()
    }

    func beginTempoRamp() {
        guard !isRecording,
              practiceSettings.tempoRampEnabled,
              practiceSettings.loopRange != nil else { return }
        if !practiceSettings.isLoopEnabled {
            setLoopEnabled(true)
        }
        completedRepetitions = 0
        isTempoRampHeld = false
        setPlaybackRate(practiceSettings.tempoRampStart)
    }

    func toggleTempoRampHold() {
        isTempoRampHeld.toggle()
    }

    func stopStructuredPractice() {
        loopResumeTask?.cancel()
        completedRepetitions = 0
        isTempoRampHeld = true
        pause()
    }

    func saveCurrentSection() {
        guard let loop = practiceSettings.loopRange else { return }
        let number = practiceSettings.savedSections.count + 1
        let commonNames = ["Intro", "Verse", "Chorus", "Bridge", "Solo", "Outro"]
        let defaultName = number <= commonNames.count
            ? commonNames[number - 1]
            : "Section \(number)"
        practiceSettings.savedSections.append(
            SavedPracticeSection(
                name: defaultName,
                start: loop.start,
                end: loop.end
            )
        )
        persistPracticeSettings()
    }

    func loadSection(_ id: UUID) {
        guard !isRecording,
              let section = practiceSettings.savedSections.first(
                where: { $0.id == id }
              ) else { return }
        updateSavedLoop(start: section.start, end: section.end)
        setLoopEnabled(true)
        seek(to: section.start)
        completedRepetitions = 0
    }

    func renameSection(_ id: UUID, to name: String) {
        guard let index = practiceSettings.savedSections.firstIndex(
            where: { $0.id == id }
        ) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        practiceSettings.savedSections[index].name = trimmed.isEmpty ? "Section" : trimmed
        persistPracticeSettings()
    }

    func deleteSection(_ id: UUID) {
        practiceSettings.savedSections.removeAll { $0.id == id }
        persistPracticeSettings()
    }

    func setPracticeTarget(_ target: StemKind) {
        guard activeStems.contains(target) else { return }
        practiceSettings.target = target
        persistPracticeSettings()
    }

    func applyTargetPreset(_ preset: TargetMixPreset) {
        guard let target = practiceSettings.target,
              activeStems.contains(target) else { return }
        soloedStem = nil
        for stem in activeStems {
            let value: Float
            switch preset {
            case .learn:
                value = stem == target ? 1 : 0
            case .guide:
                value = stem == target ? 0.3 : 1
            case .playAlong:
                value = stem == target ? 0 : 1
            }
            volumes[stem] = value
            if value > 0 { lastAudibleVolumes[stem] = value }
        }
        practiceSettings.preset = preset
        applyStemVolumes()
        persistStemLevels()
        persistPracticeSettings()
    }

    func resetPracticeSettings() {
        guard let currentTrackID else { return }
        cancelCountIn()
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        practiceFlushTask?.cancel()
        practiceFlushTask = nil
        practiceThrottle.reset()
        practiceSettingsStore.reset(for: currentTrackID)
        practiceSettings = SongPracticeSettings()
        practiceSettings.validate(duration: duration, availableStems: activeStems)
        playbackState.clearLoop()
        playbackState.setRate(1)
        playbackState.setPitchSemitones(0)
        playbackState.seek(to: 0)
        resetMix()
        completedRepetitions = 0
        isTempoRampHeld = false
        if shouldResume { requestPlayback() }
    }

    func toggleRecording() async {
        if isCountingIn {
            cancelCountIn()
            return
        }
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
        if value > 0 { lastAudibleVolumes[stem] = value }
        applyStemVolumes()
        persistStemLevels()
    }

    func volume(for stem: StemKind) -> Float { volumes[stem] ?? 1 }

    var hasCustomMix: Bool {
        activeStems.contains { abs((volumes[$0] ?? 1) - 1) > 0.001 }
    }

    func toggleMute(for stem: StemKind) {
        if (volumes[stem] ?? 1) == 0 {
            setVolume(lastAudibleVolumes[stem] ?? 1, for: stem)
        } else {
            lastAudibleVolumes[stem] = volumes[stem] ?? 1
            setVolume(0, for: stem)
        }
    }

    func toggleSolo(for stem: StemKind) {
        soloedStem = soloedStem == stem ? nil : stem
        applyStemVolumes()
    }

    func resetMix() {
        soloedStem = nil
        for stem in activeStems {
            volumes[stem] = 1
            lastAudibleVolumes[stem] = 1
        }
        applyStemVolumes()
        persistStemLevels()
    }

    func applyPracticePreset(_ preset: PracticeMixPreset) {
        soloedStem = nil
        for stem in activeStems {
            let value: Float
            switch preset {
            case .fullMix: value = 1
            case .withoutVocals: value = stem == .vocals ? 0 : 1
            case .vocalsOnly: value = stem == .vocals ? 1 : 0
            }
            volumes[stem] = value
            if value > 0 { lastAudibleVolumes[stem] = value }
        }
        applyStemVolumes()
        persistStemLevels()
    }

    func unload() {
        cancelPendingPlaybackRequest()
        if isRecording { stopRecording() }
        // Persist before stopping: `stop(resetPosition:)` rewinds to zero, and
        // saving after it would replace the resume point with the start of the
        // song every time the user closes a track.
        persistPracticeSettings(immediately: true)
        stop(resetPosition: true, releaseSession: true)
        files.removeAll()
        cancelCountIn()
        loopResumeTask?.cancel()
        playbackState.unload()
        title = ""
        separationModel = .htdemucs
        activeStems = []
        soloedStem = nil
        currentTrackID = nil
        practiceSettings = SongPracticeSettings()
        isLoaded = false
        recordedTake = nil
        activeTimingStem = nil
        nowPlaying.clear()
    }

    private func startRecording() async throws {
        guard isLoaded else { throw PlayerError.noTrack }
        cancelPendingPlaybackRequest()
        isLoopTakeRecording = practiceSettings.isLoopEnabled
            && practiceSettings.loopRange != nil
        microphonePermissionDenied = false
        guard await microphonePermissionGranted() else {
            microphonePermissionDenied = true
            isLoopTakeRecording = false
            throw PlayerError.microphoneDenied
        }

        if isLoopTakeRecording, let loop = playbackState.loopRange {
            seek(to: loop.start)
        }
        if practiceSettings.countInClicks > 0 {
            let completed = await performCountIn()
            guard completed else {
                isLoopTakeRecording = false
                return
            }
        }

        let resumePosition = position
        pausePlayback()
        engine.stop()
        playbackState.seek(to: resumePosition)
        do { try configureRecordingSession() }
        catch { throw PlayerError.audioSetup("Could not activate microphone mode", error) }
        // Merely materializing the engine's input node can complete the switch
        // to a duplex hardware route. Do it before waiting for the route to
        // settle so its configuration notification cannot race recording.
        let inputNode = engine.inputNode
        _ = inputNode.outputFormat(forBus: 0)
        // Activating microphone input changes Bluetooth headphones from A2DP
        // playback to the HFP duplex route. Let that Core Audio
        // reconfiguration finish before reading formats or installing taps.
        // Otherwise the delayed engine-configuration notification can stop a
        // recording immediately after it starts.
        try await waitForRecordingRouteToSettle()

        // The take is captured into a hidden staging directory. Library
        // discovery skips hidden entries, so an interrupted or failed take
        // cannot be found as a performance; `stopRecording` renames the folder
        // into place only once both files have been validated.
        let recording: (id: UUID, staging: URL)
        do { recording = try makeRecordingStagingFolder() }
        catch {
            logger.error(
                "Could not create a recording staging folder: \(error.localizedDescription, privacy: .public)"
            )
            throw PlayerError.noRecordingStorage
        }
        let folder = recording.staging
        let micURL = folder.appendingPathComponent("microphone.caf")
        let mixURL = folder.appendingPathComponent("backing.caf")
        let microphoneFormat = inputNode.outputFormat(forBus: 0)
        guard microphoneFormat.sampleRate > 0 else {
            LibraryStaging.discard(folder)
            throw PlayerError.noMicrophone
        }

        // Both taps must hold their file behind a `Sendable` type. A bare
        // `AVAudioFile` capture makes Swift infer the tap closure as
        // main-actor isolated — because the closure is written inside a
        // `@MainActor` method and a non-`Sendable` capture cannot cross actors
        // — and the runtime then traps the moment AVFAudio calls it on the
        // render thread. Marking the closures `@Sendable` keeps that inference
        // from happening at all.
        let micWriter: AudioTapFileWriter
        do {
            micWriter = try AudioTapFileWriter(
                url: micURL,
                settings: microphoneFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            LibraryStaging.discard(folder)
            throw PlayerError.audioSetup("Could not create recording files", error)
        }
        let mixWriter = AudioTapFileWriter(url: mixURL)

        let takeID = recording.id
        // A write failure ends the take rather than being printed and ignored.
        // Both writers report at most once, and the first one to report wins.
        micWriter.setFailureHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.recordingWriterFailed(error, stage: "microphone", takeID: takeID)
            }
        }
        mixWriter.setFailureHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.recordingWriterFailed(error, stage: "backing", takeID: takeID)
            }
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: microphoneFormat
        ) { @Sendable [weak self] buffer, _ in
            micWriter.write(buffer)
            let level = Self.meterLevel(for: buffer)
            Task { @MainActor [weak self] in
                guard let self, self.recordingID == takeID, self.isRecording else { return }
                self.microphoneMeterLevel = level
            }
        }
        // The mixer format reported before engine.start() can still describe
        // the old A2DP route. A nil tap format follows the actual render
        // format, and the writer creates the CAF from the first real buffer.
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: nil
        ) { @Sendable buffer, _ in
            mixWriter.write(buffer)
        }

        microphoneWriter = micWriter
        backingWriter = mixWriter
        microphoneURL = micURL
        backingURL = mixURL
        recordingStagingFolder = folder
        recordingWriteFailure = nil
        recordingID = recording.id
        recordingStartedAt = Date()
        activeRecordingMicrophoneLevel = recordingMicrophoneLevel
        activeRecordingBackingLevel = recordingBackingLevel
        recordingDuration = 0
        microphoneMeterLevel = 0
        recordedTake = nil
        isRecording = true
        recordingRouteTransitionDeadline = Date().addingTimeInterval(2)
        publishNowPlaying()

        do { try play() }
        catch {
            engine.stop()
            removeRecordingTaps()
            rebuildPlaybackEngine()
            isRecording = false
            isLoopTakeRecording = false
            recordingRouteTransitionDeadline = .distantPast
            deactivateAudioSession()
            discardRecordingStaging()
            throw PlayerError.audioSetup("Could not start the audio engine", error)
        }
        logger.info("Performance recording started")
    }

    /// Runs on the microphone tap's render thread for every 4096-frame buffer,
    /// so the per-sample Swift loop it replaces was real work in the audio
    /// path. `vDSP_rmsqv` gives the same value vectorized.
    private nonisolated static func meterLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return 0 }
        var sumOfSquares: Float = 0
        for channelIndex in 0..<channelCount {
            var channelRMS: Float = 0
            vDSP_rmsqv(channels[channelIndex], 1, &channelRMS, vDSP_Length(frameCount))
            sumOfSquares += channelRMS * channelRMS * Float(frameCount)
        }
        let sampleCount = Float(frameCount * channelCount)
        let rms = sqrt(sumOfSquares / sampleCount)
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }

    private nonisolated static func geometry(of file: AVAudioFile) -> StemFileGeometry {
        StemFileGeometry(
            length: file.length,
            sampleRate: file.processingFormat.sampleRate
        )
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let recordingStartedAt {
            recordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        updatePosition()
        isRecording = false
        isLoopTakeRecording = false
        recordingRouteTransitionDeadline = .distantPast

        // Stop every render and input resource before removing the taps. This
        // both stops the backing track at the end of a take and releases the
        // microphone route so iOS can dismiss its recording indicator.
        playbackState.beginNewGeneration()
        for node in nodes.values { node.stop() }
        metronomeNode.stop()
        engine.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        removeRecordingTaps()
        rebuildPlaybackEngine()
        deactivateAudioSession()
        microphoneMeterLevel = 0
        isEchoCancellationActive = false
        publishNowPlaying()

        guard let stagingMicrophoneURL = microphoneURL,
              let stagingBackingURL = backingURL,
              let stagingFolder = recordingStagingFolder,
              let recordingID else { return }

        if let failure = recordingWriteFailure {
            discardRecordingStaging()
            alertMessage = Self.recordingWriteFailureMessage(failure)
            logger.error(
                "Discarding a performance recording after a write failure: \(failure.localizedDescription, privacy: .public)"
            )
            flushPracticeSettings()
            return
        }

        // Nothing is published until both streams are closed and both files
        // open, hold audio, and agree about how long the take was.
        guard let validated = Self.validateStagedTake(
            microphoneURL: stagingMicrophoneURL,
            backingURL: stagingBackingURL
        ) else {
            discardRecordingStaging()
            recordingDuration = 0
            alertMessage = "No usable audio was captured. Check the microphone route and try recording again."
            logger.warning("Discarding an unusable performance recording")
            flushPracticeSettings()
            return
        }
        recordingDuration = validated

        let destination = stagingFolder
            .deletingLastPathComponent()
            .appendingPathComponent(recordingID.uuidString, isDirectory: true)
        let take: RecordedTake
        do {
            let metadata = RecordingMetadata(
                id: recordingID,
                title: title,
                createdAt: Date(),
                duration: validated,
                sourceTrackID: currentTrackID,
                microphoneLevel: activeRecordingMicrophoneLevel,
                backingLevel: activeRecordingBackingLevel,
                exportedFilename: nil
            )
            // Metadata goes in while the folder is still staged, so the commit
            // publishes a complete performance in one step.
            try LibraryMetadata.write(
                metadata,
                to: stagingFolder.appendingPathComponent(LibraryMetadata.recordingFilename)
            )
            try LibraryStaging.commit(stagingFolder, to: destination)
            take = RecordedTake(
                id: metadata.id,
                title: metadata.title,
                microphoneURL: destination.appendingPathComponent(
                    stagingMicrophoneURL.lastPathComponent
                ),
                backingURL: destination.appendingPathComponent(
                    stagingBackingURL.lastPathComponent
                ),
                microphoneLevel: metadata.microphoneLevel ?? 1,
                backingLevel: metadata.backingLevel ?? 0.7,
                duration: metadata.duration,
                createdAt: metadata.createdAt
            )
        } catch {
            discardRecordingStaging()
            alertMessage = "The recording could not be saved: \(error.localizedDescription)"
            logger.error(
                "Could not commit a performance recording: \(error.localizedDescription, privacy: .public)"
            )
            flushPracticeSettings()
            return
        }

        recordingStagingFolder = nil
        microphoneURL = take.microphoneURL
        backingURL = take.backingURL
        recordedTake = take
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        logger.info("Performance recording stopped after \(validated, privacy: .public) seconds")
        flushPracticeSettings()
        RecordingExportCenter.shared.start(take, sourceTrackID: currentTrackID)
    }

    /// Ends the take the moment a writer reports it cannot keep the audio.
    /// Continuing would produce a performance that is silently missing sound.
    private func recordingWriterFailed(_ error: Error, stage: String, takeID: UUID) {
        guard isRecording, recordingID == takeID else { return }
        guard recordingWriteFailure == nil else { return }
        recordingWriteFailure = error
        logger.error(
            "The \(stage, privacy: .public) writer failed: \(error.localizedDescription, privacy: .public)"
        )
        stopRecording()
    }

    private static func recordingWriteFailureMessage(_ error: Error) -> String {
        if let writerError = error as? AudioTapFileWriter.WriterError,
           writerError == .backlog {
            return "Recording stopped because audio could not be written fast enough. Free up storage or close other apps, then try again."
        }
        return "Recording stopped because it could not be written to storage: \(error.localizedDescription)"
    }

    /// Both files must open, contain audio, and describe roughly the same span
    /// of time — they are captured over one window, so a large disagreement
    /// means one of the streams stopped early. Returns the take's duration.
    nonisolated static func validateStagedTake(
        microphoneURL: URL,
        backingURL: URL
    ) -> TimeInterval? {
        guard let microphone = LibraryStaging.audioDuration(at: microphoneURL),
              let backing = LibraryStaging.audioDuration(at: backingURL) else { return nil }
        let shorter = min(microphone, backing)
        let longer = max(microphone, backing)
        guard shorter >= 0.25 else { return nil }
        guard longer - shorter <= max(2, longer * 0.35) else { return nil }
        return shorter
    }

    private func discardRecordingStaging() {
        if let recordingStagingFolder {
            LibraryStaging.discard(recordingStagingFolder)
        }
        recordingStagingFolder = nil
        microphoneURL = nil
        backingURL = nil
        recordedTake = nil
    }

    private func removeRecordingTaps() {
        engine.inputNode.removeTap(onBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        // `finish()` drains anything still queued before closing, and reports
        // the first failure the writer saw even if it happened too late to
        // stop the take itself.
        if let failure = microphoneWriter?.finish() {
            recordingWriteFailure = recordingWriteFailure ?? failure
        }
        microphoneWriter = nil
        if let failure = backingWriter?.finish() {
            recordingWriteFailure = recordingWriteFailure ?? failure
        }
        backingWriter = nil
        recordingStartedAt = nil
    }

    /// Recording instantiates the engine's RemoteIO input path. Resetting that
    /// engine does not remove the input unit, and starting it later under a
    /// playback-only session can fail with Core Audio FourCC "what". Replace
    /// the engine so subsequent playback owns a clean output-only graph.
    private func rebuildPlaybackEngine() {
        let oldEngine = engine
        NotificationCenter.default.removeObserver(
            self,
            name: .AVAudioEngineConfigurationChange,
            object: oldEngine
        )
        oldEngine.stop()

        let replacement = AVAudioEngine()
        let replacementMetronome = AVAudioPlayerNode()
        var replacementNodes: [StemKind: AVAudioPlayerNode] = [:]
        var replacementTimePitchNodes: [StemKind: AVAudioUnitTimePitch] = [:]
        for stem in StemKind.allCases {
            let node = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            replacementNodes[stem] = node
            replacementTimePitchNodes[stem] = timePitch
            replacement.attach(node)
            replacement.attach(timePitch)
        }
        replacement.attach(replacementMetronome)
        replacement.connect(
            replacementMetronome,
            to: replacement.mainMixerNode,
            format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.metronomeSampleRate,
                channels: 1,
                interleaved: false
            )
        )
        for stem in activeStems {
            guard let node = replacementNodes[stem],
                  let timePitch = replacementTimePitchNodes[stem],
                  let file = files[stem] else { continue }
            replacement.connect(node, to: timePitch, format: file.processingFormat)
            replacement.connect(
                timePitch,
                to: replacement.mainMixerNode,
                format: file.processingFormat
            )
        }

        engine = replacement
        metronomeNode = replacementMetronome
        nodes = replacementNodes
        timePitchNodes = replacementTimePitchNodes
        applyPlaybackTransform()
        applyStemVolumes()
        applyMetronomeLevel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: replacement
        )
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

    /// Waits until the activated input/output route has remained unchanged
    /// across two checks. AirPods need a short handoff from A2DP to HFP when
    /// microphone input is enabled.
    private func waitForRecordingRouteToSettle() async throws {
        let session = AVAudioSession.sharedInstance()
        var previousSignature = recordingRouteSignature(session)
        var stableChecks = 0
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(100))
            let signature = recordingRouteSignature(session)
            if signature == previousSignature,
               session.sampleRate > 0,
               session.inputNumberOfChannels > 0,
               session.outputNumberOfChannels > 0 {
                stableChecks += 1
                if stableChecks >= 2 { return }
            } else {
                stableChecks = 0
            }
            previousSignature = signature
        }
    }

    private func recordingRouteSignature(_ session: AVAudioSession) -> String {
        let inputs = session.currentRoute.inputs.map {
            "\($0.portType.rawValue):\($0.uid)"
        }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map {
            "\($0.portType.rawValue):\($0.uid)"
        }.joined(separator: ",")
        return "\(inputs)|\(outputs)|\(session.sampleRate)|\(session.inputNumberOfChannels)|\(session.outputNumberOfChannels)"
    }

    private func makeRecordingStagingFolder() throws -> (id: UUID, staging: URL) {
        let root = try LibraryStaging.libraryRoot(named: "Recordings")
        return (UUID(), try LibraryStaging.makeDirectory(in: root))
    }

    private func pausePlayback(source: TransportSource = .internalLogic) {
        transportSource = source
        updatePosition()
        playbackState.beginNewGeneration()
        for node in nodes.values { node.stop() }
        metronomeNode.stop()
        timer?.invalidate()
        timer = nil
        // Pause the engine, not just the player nodes. A live engine keeps the
        // audio session rendering, and the system infers playback state from
        // that rather than from what we publish — so the lock screen showed a
        // pause button while we were paused, and a headphone pinch sent us
        // another `pause` (a no-op) instead of `play`. `pause()` stops the
        // hardware without discarding resources, so resuming stays cheap.
        engine.pause()
        isPlaying = false
        noteDiagnosticPlaybackStopped()
        persistPracticeSettings()
        publishNowPlaying()
        logDiagnosticEvent(
            "pause",
            detail: String(format: "position=%.3f source=%@", position, transportSource.rawValue)
        )
        transportSource = .internalLogic
    }

    private func stop(resetPosition: Bool, releaseSession: Bool = false) {
        playbackState.beginNewGeneration()
        for node in nodes.values { node.stop() }
        metronomeNode.stop()
        engine.stop()
        engine.reset()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        if resetPosition { playbackState.seek(to: 0) }
        if releaseSession { deactivateAudioSession() }
        noteDiagnosticPlaybackStopped()
        publishNowPlaying()
    }

    private func beginTimer() {
        timer?.invalidate()
        // `Timer.scheduledTimer` installs into `.default`, which the run loop
        // leaves while a scroll is tracking — the playhead used to freeze for
        // as long as the user kept a finger down. `.common` keeps it firing,
        // and keeps loop bookkeeping and metronome refills running with it.
        let timer = Timer(
            timeInterval: 0.1,
            target: self,
            selector: #selector(timerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func timerFired() {
        updatePosition()
        refillMetronomeClicks()
        #if DEBUG
        diagnostics.tick(
            activeStems: activeStems,
            nodes: nodes,
            position: position,
            isPlaying: isPlaying,
            outputLatency: outputLatency
        )
        #endif
    }

    /// Records a labelled point in the device verification sequence.
    /// Compiles out of Release builds.
    func logDiagnosticEvent(_ name: String, detail: String = "") {
        #if DEBUG
        diagnostics.event(name, detail: detail)
        #endif
    }

    /// Tells the harness that playback stopped, so the paused stretch is not
    /// counted as a timer stall. The timer is invalidated on pause, so it
    /// cannot notice this by itself.
    private func noteDiagnosticPlaybackStopped() {
        #if DEBUG
        diagnostics.playbackStopped()
        #endif
    }

    /// Prints and resets the running worst-case drift and tick-gap figures.
    func summarizeDiagnostics(_ label: String) {
        #if DEBUG
        diagnostics.summarize(label)
        #endif
    }

    private func applyPlaybackTransform() {
        for stem in activeStems {
            timePitchNodes[stem]?.rate = playbackState.rate
            timePitchNodes[stem]?.pitch = playbackState.pitchSemitones * 100
        }
    }

    /// Queues the same source-time range on every stem. A single timing stem
    /// owns completions, preventing N callbacks from starting N loop passes.
    private func schedulePass(from start: TimeInterval, generation: Int) {
        let end = playbackState.loopRange?.end ?? playbackState.duration
        // The timing stem must be one that actually has frames in this range.
        // Taking `activeStems.first` unconditionally meant a short or
        // truncated first stem silently killed position updates and loop
        // completions for the whole track.
        guard end > start,
              let timingStem = StemScheduling.timingStem(
                among: activeStems,
                geometry: { stem in self.files[stem].map { Self.geometry(of: $0) } },
                from: start,
                to: end
              ) else {
            playbackCompleted(generation: generation)
            return
        }
        if timingStem != activeStems.first, timingStem != activeTimingStem {
            logger.warning(
                "Timing stem fell back to \(timingStem.rawValue, privacy: .public); the first stem scheduled no frames"
            )
        }
        activeTimingStem = timingStem

        beginMetronomePass(from: start, to: end)
        scheduledRenderDuration += (end - start) / Double(max(0.01, playbackState.rate))
        for stem in activeStems {
            guard let file = files[stem], let node = nodes[stem] else { continue }
            let segment = StemScheduling.segment(
                for: Self.geometry(of: file),
                from: start,
                to: end
            )
            let startingFrame = segment.startingFrame
            let frameCount = segment.frameCount
            guard frameCount > 0 else { continue }

            if stem == timingStem {
                let nextCompletionStopsAtTarget =
                    practiceSettings.repetitionTarget > 0
                    && completedRepetitions + 1 >= practiceSettings.repetitionTarget
                let nextCompletionChangesRate =
                    practiceSettings.tempoRampEnabled
                    && !isTempoRampHeld
                    && (completedRepetitions + 1).isMultiple(
                        of: max(1, practiceSettings.tempoRampEvery)
                    )
                let callbackType: AVAudioPlayerNodeCompletionCallbackType =
                    playbackState.loopRange == nil
                        || isLoopTakeRecording
                        || practiceSettings.repetitionPause > 0
                        || nextCompletionStopsAtTarget
                        || nextCompletionChangesRate
                        ? .dataPlayedBack
                        : .dataConsumed
                node.scheduleSegment(
                    file,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    at: nil,
                    completionCallbackType: callbackType
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.isRecording && self.isLoopTakeRecording {
                            self.playbackState.seek(to: self.playbackState.loopRange?.end ?? self.duration)
                            self.stopRecording()
                        } else if let loop = self.playbackState.loopRange {
                            self.scheduleNextLoopPass(
                                from: loop.start,
                                generation: generation
                            )
                        } else {
                            self.playbackCompleted(generation: generation)
                        }
                    }
                }
            } else {
                node.scheduleSegment(
                    file,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    at: nil
                )
            }
        }
    }

    private func scheduleNextLoopPass(from start: TimeInterval, generation: Int) {
        guard isPlaying,
              generation == playbackState.playbackGeneration,
              playbackState.loopRange != nil else { return }
        completedRepetitions += 1
        logDiagnosticEvent("loopWrap", detail: "repetition=\(completedRepetitions)")
        if practiceSettings.repetitionTarget > 0,
           completedRepetitions >= practiceSettings.repetitionTarget {
            playbackState.seek(to: playbackState.loopRange?.end ?? position)
            stop(resetPosition: false, releaseSession: true)
            return
        }

        let shouldRamp = practiceSettings.tempoRampEnabled
            && !isTempoRampHeld
            && completedRepetitions.isMultiple(
                of: max(1, practiceSettings.tempoRampEvery)
            )
            && playbackState.rate < practiceSettings.tempoRampTarget
        if shouldRamp {
            let nextRate = min(
                practiceSettings.tempoRampTarget,
                playbackState.rate + practiceSettings.tempoRampIncrement
            )
            restartLoop(at: start, rate: nextRate, after: practiceSettings.repetitionPause)
        } else if practiceSettings.repetitionPause > 0 {
            restartLoop(at: start, rate: nil, after: practiceSettings.repetitionPause)
        } else {
            schedulePass(from: start, generation: generation)
        }
    }

    private func playbackCompleted(generation: Int) {
        guard generation == playbackState.playbackGeneration, isPlaying else { return }
        playbackState.seek(to: duration)
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
        guard isPlaying,
              let node = timingNode(),
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return }
        playbackState.updatePosition(
            renderSampleTime: playerTime.sampleTime,
            sampleRate: playerTime.sampleRate,
            anchorPosition: renderAnchorPosition,
            outputLatency: outputLatency
        )
        persistPracticeSettings()
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

    private func cancelPendingPlaybackRequest() {
        playbackRequestID += 1
    }

    private nonisolated static func isTransientAudioIOStartFailure(_ error: Error) -> Bool {
        var candidate: NSError? = error as NSError
        while let current = candidate {
            if current.code == 2_003_329_396 { return true } // FourCC "what"
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private nonisolated static func playbackStartupMessage(for error: Error) -> String {
        guard isTransientAudioIOStartFailure(error) else {
            return error.localizedDescription
        }
        return "Audio output could not start. Check that no call or another app is using audio, then reconnect headphones if needed and try again."
    }

    private func effectiveVolume(for stem: StemKind) -> Float {
        if practiceSettings.metronomeOnly, practiceSettings.metronomeEnabled {
            return 0
        }
        guard let soloedStem else { return volumes[stem] ?? 1 }
        return soloedStem == stem ? (volumes[stem] ?? 1) : 0
    }

    private func applyStemVolumes() {
        for stem in activeStems {
            nodes[stem]?.volume = effectiveVolume(for: stem)
        }
    }

    private func persistStemLevels() {
        guard let currentTrackID else { return }
        let values = Dictionary(uniqueKeysWithValues: activeStems.map {
            ($0.rawValue, Double(volumes[$0] ?? 1))
        })
        UserDefaults.standard.set(
            values,
            forKey: Self.stemLevelDefaultsPrefix + currentTrackID.uuidString
        )
    }

    private func updateSavedLoop(start: TimeInterval, end: TimeInterval) {
        guard let range = PlaybackLoopRange(
            start: start,
            end: end,
            duration: duration
        ) else { return }
        practiceSettings.loopStart = range.start
        practiceSettings.loopEnd = range.end
        if practiceSettings.isLoopEnabled {
            _ = setLoop(start: range.start, end: range.end)
        }
        persistPracticeSettings()
    }

    /// Saves practice state, at most once every
    /// `practicePersistenceInterval` seconds.
    ///
    /// Every mutating entry point calls this, and several call it twice for
    /// one user action — a single seek used to pause (one write) and then
    /// persist (another), encoding the whole settings blob into `UserDefaults`
    /// twice per tap. Suppressed writes are not dropped: the last one is
    /// scheduled so the state still lands once the interval elapses.
    private func persistPracticeSettings(immediately: Bool = false) {
        guard let currentTrackID else { return }
        practiceSettings.lastPosition = position
        practiceSettings.playbackRate = playbackState.rate
        practiceSettings.pitchSemitones = playbackState.pitchSemitones
        guard practiceThrottle.shouldWrite(force: immediately) else {
            schedulePracticeSettingsFlush()
            return
        }
        practiceFlushTask?.cancel()
        practiceFlushTask = nil
        practiceSettingsStore.save(practiceSettings, for: currentTrackID)
    }

    private func schedulePracticeSettingsFlush() {
        // While the position timer runs it retries every 100 ms, so the
        // suppressed write already lands within the interval. Scheduling a
        // second one would just race it at the boundary and double the writes.
        guard !isPlaying, practiceFlushTask == nil else { return }
        let delay = practiceThrottle.delayUntilNextWrite()
        practiceFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.practiceFlushTask = nil
            guard self.practiceThrottle.hasPendingWrite else { return }
            self.persistPracticeSettings(immediately: true)
        }
    }

    /// Writes any suppressed practice state straight away.
    ///
    /// Call this whenever the state could stop existing before the throttle
    /// expires — leaving the song, or the app going to the background.
    func flushPracticeSettings() {
        guard practiceThrottle.hasPendingWrite else { return }
        persistPracticeSettings(immediately: true)
    }

    private func cancelCountIn() {
        countInGeneration &+= 1
        countInTask?.cancel()
        countInTask = nil
        countInRemaining = 0
    }

    private func performCountIn() async -> Bool {
        let clicks = practiceSettings.countInClicks
        guard clicks > 0 else { return true }
        countInGeneration &+= 1
        let generation = countInGeneration
        for remaining in stride(from: clicks, through: 1, by: -1) {
            guard !Task.isCancelled, generation == countInGeneration else {
                countInRemaining = 0
                return false
            }
            countInRemaining = remaining
            AudioServicesPlaySystemSound(1104)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                countInRemaining = 0
                return false
            }
        }
        countInRemaining = 0
        return !Task.isCancelled && generation == countInGeneration
    }

    private func restoreStemLevels(for trackID: UUID) {
        let key = Self.stemLevelDefaultsPrefix + trackID.uuidString
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        for stem in activeStems {
            let value = Float(saved?[stem.rawValue] ?? 1)
            volumes[stem] = min(1, max(0, value))
            lastAudibleVolumes[stem] = value > 0 ? value : 1
        }
    }

    private func persistAndRestartIfPlaying() {
        persistPracticeSettings()
        guard isPlaying else { return }
        let resumePosition = position
        pausePlayback()
        playbackState.seek(to: resumePosition)
        requestPlayback()
    }

    private func clampedRate(_ rate: Float) -> Float {
        min(
            max(rate, PlaybackState.supportedRateRange.lowerBound),
            PlaybackState.supportedRateRange.upperBound
        )
    }

    private func restartLoop(
        at start: TimeInterval,
        rate: Float?,
        after pause: TimeInterval
    ) {
        let expectedGeneration = playbackState.playbackGeneration
        loopResumeTask?.cancel()
        loopResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.forEachPlaybackNode { $0.stop() }
            self.metronomeNode.stop()
            self.timer?.invalidate()
            self.timer = nil
            self.isPlaying = false
            self.playbackState.seek(to: start)
            if let rate {
                self.playbackState.setRate(rate)
                self.practiceSettings.playbackRate = self.playbackState.rate
                self.applyPlaybackTransform()
                self.persistPracticeSettings()
            }
            if pause > 0 {
                try? await Task.sleep(for: .seconds(pause))
            }
            guard !Task.isCancelled,
                  expectedGeneration == self.playbackState.playbackGeneration else { return }
            self.requestPlayback()
        }
    }

    private func forEachPlaybackNode(_ body: (AVAudioPlayerNode) -> Void) {
        for node in nodes.values { body(node) }
    }

    // MARK: - Metronome

    /// Pre-renders the two click voices once.
    ///
    /// The old implementation synthesized a click track covering the whole
    /// remaining song on the main actor inside `play()` — a nine-minute track
    /// meant allocating and filling a ~4.3 million sample buffer on every
    /// press of play. Two ~18 ms buffers are enough; scheduling places them.
    private nonisolated static func makeClickBuffers() -> [Bool: AVAudioPCMBuffer] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: metronomeSampleRate,
            channels: 1,
            interleaved: false
        ) else { return [:] }
        var buffers: [Bool: AVAudioPCMBuffer] = [:]
        for isAccented in [false, true] {
            let frequency = isAccented ? 1_600.0 : 1_050.0
            let gain: Float = isAccented ? 1 : 0.72
            let frameCount = AVAudioFrameCount(max(1, metronomeSampleRate * 0.018))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ), let samples = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = frameCount
            for offset in 0..<Int(frameCount) {
                let envelope = Float(Int(frameCount) - offset) / Float(frameCount)
                let phase = 2 * Double.pi * frequency * Double(offset) / metronomeSampleRate
                samples[offset] = Float(sin(phase)) * envelope * gain
            }
            buffers[isAccented] = buffer
        }
        return buffers
    }

    /// Click level is a node gain, not something baked into the buffers, so
    /// changing it does not require re-rendering or restarting playback.
    private func applyMetronomeLevel() {
        metronomeNode.volume = min(max(practiceSettings.metronomeLevel, 0), 1)
    }

    /// Starts a click grid for the source range a playback pass just queued.
    ///
    /// Clicks are placed on the metronome node's own timeline, which shares
    /// its origin with the stems because both nodes are started at the same
    /// host time. That keeps the clicks inside the pass's loop and recording
    /// boundaries, and captured by the backing-mix tap, exactly as before.
    private func beginMetronomePass(from start: TimeInterval, to end: TimeInterval) {
        metronomePlan = MetronomeClickPlan(
            sourceStart: start,
            sourceEnd: end,
            renderOrigin: scheduledRenderDuration,
            bpm: Double(practiceSettings.metronomeBPM),
            clicksPerBeat: practiceSettings.metronomeSubdivision.clicksPerBeat,
            alignment: practiceSettings.metronomeAlignment,
            accentsEnabled: practiceSettings.metronomeAccentEnabled,
            rate: Double(playbackState.rate)
        )
        metronomePlan.reset()
        guard practiceSettings.metronomeEnabled else { return }
        scheduleMetronomeClicks(
            through: metronomePlan.renderOrigin + Self.metronomeScheduleWindow
        )
    }

    /// Tops the click queue back up to the rolling window. Driven by the
    /// position timer, so it also keeps running while the user scrolls.
    private func refillMetronomeClicks() {
        guard practiceSettings.metronomeEnabled, isPlaying else { return }
        let elapsed = currentMetronomeRenderElapsed() ?? metronomePlan.renderOrigin
        scheduleMetronomeClicks(through: elapsed + Self.metronomeScheduleWindow)
    }

    private func scheduleMetronomeClicks(through renderDeadline: TimeInterval) {
        guard let normal = clickBuffers[false], let accented = clickBuffers[true] else {
            return
        }
        for click in metronomePlan.clicks(through: renderDeadline) {
            let time = AVAudioTime(
                sampleTime: AVAudioFramePosition(
                    (click.renderTime * Self.metronomeSampleRate).rounded()
                ),
                atRate: Self.metronomeSampleRate
            )
            metronomeNode.scheduleBuffer(
                click.isAccented ? accented : normal,
                at: time,
                options: []
            )
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
        try session.setActive(true)
        if #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            // This input path is tuned for capturing a wider range of audio
            // while removing sound played through the built-in speaker. It is
            // unnecessary for headphones and can trigger another route change.
            let usesBuiltInOutput = session.currentRoute.outputs.contains {
                $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
            }
            if session.isEchoCancelledInputEnabled != usesBuiltInOutput {
                try session.setPrefersEchoCancelledInput(usesBuiltInOutput)
            }
        }
        if #available(iOS 18.2, *) {
            isEchoCancellationActive = session.isEchoCancelledInputEnabled
        } else {
            isEchoCancellationActive = false
        }
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let rawType =
                notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
            return
        }
        let rawOptions =
            notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor [weak self] in
            self?.processInterruption(type: rawType, options: rawOptions)
        }
    }

    private func processInterruption(type rawType: UInt, options rawOptions: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        logDiagnosticEvent(
            "interruption",
            detail: "type=\(type == .began ? "began" : "ended") wasPlaying=\(isPlaying)"
        )
        switch type {
        case .began:
            interruptionShouldResume = isPlaying && !isRecording
            if isRecording { stopRecording() }
            pausePlayback(source: .interruption)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if interruptionShouldResume, options.contains(.shouldResume) {
                requestPlayback()
            }
            interruptionShouldResume = false
        @unknown default: break
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let rawReason =
                notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
            return
        }
        Task { @MainActor [weak self] in
            self?.processRouteChange(reason: rawReason)
        }
    }

    private func processRouteChange(reason rawReason: UInt) {
        logDiagnosticEvent(
            "routeChange",
            detail: "reason=\(rawReason) isPlaying=\(isPlaying)"
        )
        // Any route change can move output latency by more than 100 ms —
        // AirPods against the built-in speaker is the usual jump — so refresh
        // the compensation even for changes that do not stop playback.
        refreshOutputLatency()
        guard AVAudioSession.RouteChangeReason(rawValue: rawReason) ==
                .oldDeviceUnavailable else {
            return
        }
        if isRecording { stopRecording() }
        pausePlayback(source: .routeChange)
    }

    @objc nonisolated private func handleEngineConfigurationChange() {
        Task { @MainActor [weak self] in
            self?.processEngineConfigurationChange()
        }
    }

    private func processEngineConfigurationChange() {
        logDiagnosticEvent(
            "engineConfigChange",
            detail: "isPlaying=\(isPlaying) isRecording=\(isRecording) engineRunning=\(engine.isRunning)"
        )
        if isRecording {
            // AVFAudio can deliver the configuration notification produced by
            // the A2DP-to-HFP handoff after engine.start() has already rebuilt
            // a healthy graph. Do not turn that stale delivery into a
            // zero-length take. A real configuration loss stops the engine;
            // route-removal and interruption notifications are handled above.
            if Date() < recordingRouteTransitionDeadline, engine.isRunning {
                logger.debug("Ignoring settled recording-route configuration notification")
                return
            }
            stopRecording()
            return
        }
        guard isPlaying else { return }
        updatePosition()
        stop(resetPosition: false)
        requestPlayback()
    }
}

/// Where a transport change came from. Diagnostic only, but it is the
/// difference between "something paused us" and a fixable bug.
enum TransportSource: String, Sendable {
    case ui
    case remote
    case scrub
    case interruption
    case routeChange
    case internalLogic = "internal"
}

enum PracticeMixPreset {
    case fullMix
    case withoutVocals
    case vocalsOnly
}

private enum PlayerError: LocalizedError {
    case incompleteTrack
    case noTrack
    case microphoneDenied
    case noMicrophone
    case noRecordingStorage
    case audioSetup(String, Error)

    var errorDescription: String? {
        switch self {
        case .incompleteTrack: "This track does not contain all of the stems produced by its separation model."
        case .noTrack: "Separate and load a song before recording."
        case .microphoneDenied: "Microphone access is required. Enable Atarang in Settings → Privacy & Security → Microphone."
        case .noMicrophone: "No microphone input is available."
        case .noRecordingStorage: "Atarang could not prepare a place to save this recording. Check that this device has free storage, then try again."
        case .audioSetup(let stage, let error): "\(stage): \(error.localizedDescription)"
        }
    }
}
