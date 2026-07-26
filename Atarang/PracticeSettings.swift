import Foundation

/// What the Stage is showing. Replaces the former Mix/Practice split: practice
/// tools are chips now, so the Stage is free to be about the song itself.
///
/// Three of the four are placeholders until Milestones C and D fill them in.
/// They ship visible and empty on purpose — the selector is the shape of the
/// screen, and hiding stages until their phase lands would mean rebuilding it
/// three more times.
enum StudioStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyrics
    case chords
    case sheet
    case mixer

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .lyrics: "text.quote"
        case .chords: "guitars"
        case .sheet: "doc.text"
        case .mixer: "slider.horizontal.3"
        }
    }
}

enum TargetMixPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case learn
    case guide
    case playAlong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .learn: "Learn"
        case .guide: "Guide"
        case .playAlong: "Play Along"
        }
    }

    var detail: String {
        switch self {
        case .learn: "Hear the target by itself"
        case .guide: "Keep the target quiet with the backing"
        case .playAlong: "Mute the target and take its place"
        }
    }
}

enum MetronomeSubdivision: String, Codable, CaseIterable, Identifiable, Sendable {
    case quarter
    case eighth
    case triplet
    case sixteenth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quarter: "Quarter"
        case .eighth: "Eighth"
        case .triplet: "Triplet"
        case .sixteenth: "Sixteenth"
        }
    }

    var clicksPerBeat: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .triplet: 3
        case .sixteenth: 4
        }
    }
}

struct SavedPracticeSection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var start: TimeInterval
    var end: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        start: TimeInterval,
        end: TimeInterval
    ) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
    }
}

struct SongPracticeSettings: Codable, Equatable, Sendable {
    /// Bumped to 2 by Phase 4: `workspace` became `stage`, with a different
    /// case set. Pre-release, so there is no migration — settings written by an
    /// earlier build no longer decode and the song starts from defaults.
    static let currentSchemaVersion = 2
    static let supportedCountInClicks = [0, 2, 4]
    static let supportedBPMRange = 30...300
    static let supportedRepetitionPauseRange: ClosedRange<TimeInterval> = 0...10

    var schemaVersion = Self.currentSchemaVersion
    var stage: StudioStage = .mixer
    var target: StemKind?
    var preset: TargetMixPreset = .learn
    var loopStart: TimeInterval?
    var loopEnd: TimeInterval?
    var isLoopEnabled = false
    var playbackRate: Float = 1
    var pitchSemitones: Float = 0
    var countInClicks = 0
    var lastPosition: TimeInterval = 0
    var metronomeEnabled = false
    var metronomeBPM = 120
    var metronomeSubdivision: MetronomeSubdivision = .quarter
    var metronomeAccentEnabled = true
    var metronomeLevel: Float = 0.7
    var metronomeAlignment: TimeInterval = 0
    var metronomeOnly = false
    var repetitionTarget = 0
    var repetitionPause: TimeInterval = 0
    var tempoRampEnabled = false
    var tempoRampEvery = 1
    var tempoRampStart: Float = 0.5
    var tempoRampIncrement: Float = 0.05
    var tempoRampTarget: Float = 1
    var savedSections: [SavedPracticeSection] = []

    var loopRange: (start: TimeInterval, end: TimeInterval)? {
        guard let loopStart, let loopEnd else { return nil }
        return (loopStart, loopEnd)
    }

    mutating func validate(duration: TimeInterval, availableStems: [StemKind]) {
        schemaVersion = Self.currentSchemaVersion
        playbackRate = min(
            max(playbackRate, PlaybackState.supportedRateRange.lowerBound),
            PlaybackState.supportedRateRange.upperBound
        )
        pitchSemitones = min(
            max(pitchSemitones, PlaybackState.supportedPitchRange.lowerBound),
            PlaybackState.supportedPitchRange.upperBound
        )
        metronomeBPM = min(
            max(metronomeBPM, Self.supportedBPMRange.lowerBound),
            Self.supportedBPMRange.upperBound
        )
        metronomeLevel = min(max(metronomeLevel, 0), 1)
        metronomeAlignment = metronomeAlignment.isFinite
            ? min(max(0, metronomeAlignment), max(0, duration))
            : 0
        repetitionTarget = min(max(0, repetitionTarget), 999)
        repetitionPause = repetitionPause.isFinite
            ? min(
                max(repetitionPause, Self.supportedRepetitionPauseRange.lowerBound),
                Self.supportedRepetitionPauseRange.upperBound
            )
            : 0
        tempoRampEvery = min(max(1, tempoRampEvery), 99)
        tempoRampStart = Self.validatedRate(tempoRampStart)
        tempoRampIncrement = min(max(tempoRampIncrement, 0.01), 0.5)
        tempoRampTarget = Self.validatedRate(tempoRampTarget)
        if tempoRampStart > tempoRampTarget {
            tempoRampStart = tempoRampTarget
        }
        countInClicks = Self.supportedCountInClicks.contains(countInClicks)
            ? countInClicks
            : 0
        lastPosition = lastPosition.isFinite
            ? min(max(0, lastPosition), max(0, duration))
            : 0

        if let target, !availableStems.contains(target) {
            self.target = nil
        }
        if target == nil {
            target = availableStems.contains(.vocals) ? .vocals : availableStems.first
        }

        savedSections = savedSections.compactMap { section in
            guard let range = PlaybackLoopRange(
                start: section.start,
                end: section.end,
                duration: duration
            ) else { return nil }
            let trimmedName = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return SavedPracticeSection(
                id: section.id,
                name: trimmedName.isEmpty ? "Section" : trimmedName,
                start: range.start,
                end: range.end
            )
        }

        guard let start = loopStart,
              let end = loopEnd,
              let range = PlaybackLoopRange(start: start, end: end, duration: duration) else {
            loopStart = nil
            loopEnd = nil
            isLoopEnabled = false
            return
        }
        loopStart = range.start
        loopEnd = range.end
    }

    init() {}

    private static func validatedRate(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(
            max(value, PlaybackState.supportedRateRange.lowerBound),
            PlaybackState.supportedRateRange.upperBound
        )
    }
}

struct PracticeSettingsStore {
    private static let keyPrefix = "practiceSettings.v1."
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for trackID: UUID) -> SongPracticeSettings {
        guard let data = defaults.data(forKey: Self.keyPrefix + trackID.uuidString),
              let settings = try? JSONDecoder().decode(
                SongPracticeSettings.self,
                from: data
              ) else {
            return SongPracticeSettings()
        }
        return settings
    }

    func save(_ settings: SongPracticeSettings, for trackID: UUID) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.keyPrefix + trackID.uuidString)
    }

    func reset(for trackID: UUID) {
        defaults.removeObject(forKey: Self.keyPrefix + trackID.uuidString)
    }
}
