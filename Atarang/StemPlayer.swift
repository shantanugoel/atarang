import AVFoundation
import AudioToolbox
import Combine
import Foundation
import OSLog

@MainActor
final class StemPlayer: ObservableObject, @unchecked Sendable {
    @Published private(set) var isLoaded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isRecording = false
    @Published private(set) var isExporting = false
    @Published private(set) var playbackState = PlaybackState()
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var title = ""
    @Published private(set) var separationModel: SeparationModelKind = .htdemucs
    @Published private(set) var activeStems: [StemKind] = []
    @Published private(set) var recordedTake: RecordedTake?
    @Published private(set) var shareURL: URL?
    @Published private(set) var practiceSettings = SongPracticeSettings()
    @Published private(set) var countInRemaining = 0
    @Published private(set) var completedRepetitions = 0
    @Published private(set) var isTempoRampHeld = false
    @Published private(set) var isLoopTakeRecording = false
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
    @Published private(set) var soloedStem: StemKind?
    @Published private(set) var microphonePermissionDenied = false
    @Published var alertMessage: String?

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

    private let engine = AVAudioEngine()
    private let metronomeNode = AVAudioPlayerNode()
    private var nodes: [StemKind: AVAudioPlayerNode] = [:]
    private var timePitchNodes: [StemKind: AVAudioUnitTimePitch] = [:]
    private var files: [StemKind: AVAudioFile] = [:]
    private var volumes = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) })
    private var lastAudibleVolumes = Dictionary(
        uniqueKeysWithValues: StemKind.allCases.map { ($0, Float(1)) }
    )
    private var timer: Timer?
    private var renderAnchorPosition: TimeInterval = 0

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
    private var countInTask: Task<Void, Never>?
    private var countInGeneration = 0
    private var lastPracticePersistenceDate = Date.distantPast
    private var tapTempoDates: [Date] = []
    private var loopResumeTask: Task<Void, Never>?
    private let practiceSettingsStore = PracticeSettingsStore()
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Audio")
    private static let microphoneLevelDefaultsKey = "recordingMicrophoneLevel"
    private static let backingLevelDefaultsKey = "recordingBackingLevel"
    private static let stemLevelDefaultsPrefix = "stemLevels."

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
                sampleRate: 8_000,
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
        isLoaded = playbackState.duration > 0
        recordedTake = nil
        shareURL = nil
        completedRepetitions = 0
        isTempoRampHeld = false
        isLoopTakeRecording = false
    }

    func togglePlayback() {
        guard !isRecording else { return }
        if isPlaying || isCountingIn {
            pause()
        } else {
            startPlaybackWithCountIn()
        }
    }

    private func startPlaybackWithCountIn() {
        cancelCountIn()
        guard practiceSettings.countInClicks > 0 else {
            do { try play() }
            catch { alertMessage = error.localizedDescription }
            return
        }
        countInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let completed = await self.performCountIn()
            guard completed else { return }
            do { try self.play() }
            catch { self.alertMessage = error.localizedDescription }
        }
    }

    func play() throws {
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
        let leadTime = 0.08
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadTime)
        let startTime = AVAudioTime(hostTime: startHostTime)
        renderAnchorPosition = position
        schedulePass(from: position, generation: generation)
        for stem in activeStems {
            nodes[stem]?.volume = effectiveVolume(for: stem)
            nodes[stem]?.play(at: startTime)
        }
        metronomeNode.play(at: startTime)
        isPlaying = true
        beginTimer()
    }

    func pause() {
        guard !isRecording else { return }
        cancelCountIn()
        pausePlayback()
    }

    /// Releases the audio engine while preserving the current playhead.
    ///
    /// History previews use a separate player. Merely pausing the stem nodes
    /// leaves this engine's output unit active, which can make the shared audio
    /// session fail when the preview player takes over.
    func suspend() {
        guard !isRecording else { return }
        cancelCountIn()
        updatePosition()
        stop(resetPosition: false, releaseSession: true)
    }

    func seek(to newPosition: TimeInterval) {
        guard !isRecording else { return }
        cancelCountIn()
        let shouldResume = isPlaying
        pausePlayback()
        playbackState.seek(to: newPosition)
        persistPracticeSettings()
        if shouldResume { try? play() }
    }

    func skipBackward(seconds: TimeInterval = 5) {
        seek(to: max(0, position - max(0, seconds)))
    }

    func setPlaybackRate(_ rate: Float) {
        guard !isRecording else { return }
        updatePosition()
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        playbackState.setRate(rate)
        practiceSettings.playbackRate = playbackState.rate
        persistPracticeSettings()
        applyPlaybackTransform()
        if shouldResume { try? play() }
    }

    func setPitchSemitones(_ semitones: Float) {
        guard !isRecording else { return }
        updatePosition()
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        playbackState.setPitchSemitones(semitones)
        practiceSettings.pitchSemitones = playbackState.pitchSemitones
        persistPracticeSettings()
        applyPlaybackTransform()
        if shouldResume { try? play() }
    }

    @discardableResult
    func setLoop(start: TimeInterval, end: TimeInterval) -> Bool {
        guard !isRecording else { return false }
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
        let accepted = playbackState.setLoop(start: start, end: end)
        if shouldResume { try? play() }
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
        if shouldResume { try? play() }
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
            if shouldResume { try? play() }
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
        persistAndRestartIfPlaying()
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
        objectWillChange.send()
    }

    func resetPracticeSettings() {
        guard let currentTrackID else { return }
        cancelCountIn()
        let shouldResume = isPlaying
        if shouldResume { pausePlayback() }
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
        if shouldResume { try? play() }
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
        objectWillChange.send()
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
        objectWillChange.send()
    }

    func resetMix() {
        soloedStem = nil
        for stem in activeStems {
            volumes[stem] = 1
            lastAudibleVolumes[stem] = 1
        }
        applyStemVolumes()
        persistStemLevels()
        objectWillChange.send()
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
        objectWillChange.send()
    }

    func unload() {
        if isRecording { stopRecording() }
        stop(resetPosition: true, releaseSession: true)
        files.removeAll()
        persistPracticeSettings()
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
        shareURL = nil
    }

    private func startRecording() async throws {
        guard isLoaded else { throw PlayerError.noTrack }
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
            isLoopTakeRecording = false
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
        updatePosition()
        isRecording = false
        isLoopTakeRecording = false

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
        playbackState.beginNewGeneration()
        for node in nodes.values { node.stop() }
        metronomeNode.stop()
        timer?.invalidate()
        timer = nil
        isPlaying = false
        persistPracticeSettings()
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
        guard end > start, let timingStem = activeStems.first else {
            playbackCompleted(generation: generation)
            return
        }

        scheduleMetronomePass(from: start, to: end)
        for stem in activeStems {
            guard let file = files[stem], let node = nodes[stem] else { continue }
            let sampleRate = file.processingFormat.sampleRate
            let startingFrame = min(
                file.length,
                AVAudioFramePosition(max(0, start) * sampleRate)
            )
            let endingFrame = min(
                file.length,
                AVAudioFramePosition(max(start, end) * sampleRate)
            )
            let frameCount = AVAudioFrameCount(max(0, endingFrame - startingFrame))
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
              let timingStem = activeStems.first,
              let node = nodes[timingStem],
              let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime) else { return }
        playbackState.updatePosition(
            renderSampleTime: playerTime.sampleTime,
            sampleRate: playerTime.sampleRate,
            anchorPosition: renderAnchorPosition
        )
        if Date().timeIntervalSince(lastPracticePersistenceDate) >= 2 {
            persistPracticeSettings()
        }
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

    private func persistPracticeSettings() {
        guard let currentTrackID else { return }
        practiceSettings.lastPosition = position
        practiceSettings.playbackRate = playbackState.rate
        practiceSettings.pitchSemitones = playbackState.pitchSemitones
        practiceSettingsStore.save(practiceSettings, for: currentTrackID)
        lastPracticePersistenceDate = Date()
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
        try? play()
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
            try? self.play()
        }
    }

    private func forEachPlaybackNode(_ body: (AVAudioPlayerNode) -> Void) {
        for node in nodes.values { body(node) }
    }

    /// Builds one lightweight click track for the currently scheduled source
    /// range. It is queued alongside the stems, so it shares their loop and
    /// recording boundaries and is captured by the backing-mix tap.
    private func scheduleMetronomePass(from start: TimeInterval, to end: TimeInterval) {
        guard practiceSettings.metronomeEnabled,
              end > start,
              playbackState.rate > 0 else { return }
        let sampleRate = 8_000.0
        let renderDuration = (end - start) / Double(playbackState.rate)
        let frameCapacity = AVAudioFrameCount(max(1, (renderDuration * sampleRate).rounded(.up)))
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCapacity
        ),
        let samples = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frameCapacity
        samples.initialize(repeating: 0, count: Int(frameCapacity))

        let bpm = Double(practiceSettings.metronomeBPM)
        let clicksPerBeat = practiceSettings.metronomeSubdivision.clicksPerBeat
        let clickInterval = 60 / bpm / Double(clicksPerBeat)
        let alignment = practiceSettings.metronomeAlignment
        let firstIndex = Int(ceil((start - alignment) / clickInterval))
        var clickIndex = firstIndex
        let clickLength = max(1, Int(sampleRate * 0.018))
        while true {
            let sourceTime = alignment + Double(clickIndex) * clickInterval
            if sourceTime >= end { break }
            if sourceTime >= start {
                let renderTime = (sourceTime - start) / Double(playbackState.rate)
                let frame = Int((renderTime * sampleRate).rounded())
                let subdivisionIndex = ((clickIndex % clicksPerBeat) + clicksPerBeat)
                    % clicksPerBeat
                let beatIndex = Int(
                    floor((sourceTime - alignment) / (60 / bpm))
                )
                let isDownbeat = subdivisionIndex == 0
                    && ((beatIndex % 4) + 4) % 4 == 0
                let frequency = isDownbeat && practiceSettings.metronomeAccentEnabled
                    ? 1_600.0
                    : 1_050.0
                let accentGain: Float = isDownbeat
                    && practiceSettings.metronomeAccentEnabled ? 1 : 0.72
                for offset in 0..<clickLength where frame + offset < Int(frameCapacity) {
                    let envelope = Float(clickLength - offset) / Float(clickLength)
                    let phase = 2 * Double.pi * frequency * Double(offset) / sampleRate
                    samples[frame + offset] += Float(sin(phase))
                        * envelope
                        * accentGain
                        * practiceSettings.metronomeLevel
                }
            }
            clickIndex += 1
        }
        metronomeNode.scheduleBuffer(buffer)
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
            interruptionShouldResume = isPlaying && !isRecording
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

    @objc private func handleEngineConfigurationChange() {
        if isRecording {
            stopRecording()
            return
        }
        guard isPlaying else { return }
        updatePosition()
        stop(resetPosition: false)
        do {
            try play()
        } catch {
            alertMessage = error.localizedDescription
        }
    }
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
