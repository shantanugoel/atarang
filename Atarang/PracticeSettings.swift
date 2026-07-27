import Foundation
import OSLog

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

/// What `validate` had to change, so the app can say so instead of quietly
/// practising something else.
struct PracticeSettingsValidation: Equatable, Sendable {
    /// The stem the user was practising, when this separation does not have it.
    var missingTarget: StemKind?
    /// What is being practised instead, if anything could be.
    var replacementTarget: StemKind?

    var targetChangeMessage: String? {
        guard let missingTarget else { return nil }
        guard let replacementTarget else {
            return "This separation has no \(missingTarget.title) stem, so there is no practice target."
        }
        return "This separation has no \(missingTarget.title) stem. Practising \(replacementTarget.title) instead."
    }
}

struct SongPracticeSettings: Codable, Equatable, Sendable {
    /// Bumped to 4 by Phase 7: the metronome can follow a detected beat grid
    /// and loop boundaries can snap to its bar lines. Pre-release, so there is
    /// no migration — settings written by an earlier build no longer decode and
    /// the song starts from defaults.
    static let currentSchemaVersion = 4
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
    /// Whether the click takes its tempo and its first downbeat from the
    /// detected beat grid.
    ///
    /// On by default, and switched off the moment the user sets a BPM or aligns
    /// the click by hand — a manual correction that a later detection could
    /// silently overwrite would not be a correction at all. Turning it back on
    /// is one tap, and with no grid, or an unreliable one, it does nothing.
    var metronomeFollowsGrid = true
    var metronomeOnly = false
    var repetitionTarget = 0
    var repetitionPause: TimeInterval = 0
    var tempoRampEnabled = false
    var tempoRampEvery = 1
    var tempoRampStart: Float = 0.5
    var tempoRampIncrement: Float = 0.05
    var tempoRampTarget: Float = 1
    /// Whether A and B land on bar lines when a reliable beat grid exists.
    ///
    /// On by default because a practice loop almost always wants to be a whole
    /// number of bars, and a loop that starts an eighth of a beat late is
    /// audibly wrong every time it wraps. The timeline's context menu sets a
    /// boundary exactly where the finger is for the times it does not.
    var snapLoopsToBars = true
    var savedSections: [SavedPracticeSection] = []
    /// Per-stem mix levels, keyed by `StemKind.rawValue`.
    ///
    /// They used to be their own `UserDefaults` entry, written on every fader
    /// move. Folding them in here means one file per song, one throttle, and one
    /// atomic write — and a mix that survives re-separation along with the rest
    /// of the practice state. Keyed by raw value rather than by `StemKind`
    /// because JSON object keys have to be strings.
    var stemLevels: [String: Float] = [:]

    var loopRange: (start: TimeInterval, end: TimeInterval)? {
        guard let loopStart, let loopEnd else { return nil }
        return (loopStart, loopEnd)
    }

    func level(for stem: StemKind) -> Float {
        stemLevels[stem.rawValue] ?? 1
    }

    mutating func setLevel(_ level: Float, for stem: StemKind) {
        stemLevels[stem.rawValue] = min(1, max(0, level))
    }

    @discardableResult
    mutating func validate(
        duration: TimeInterval,
        availableStems: [StemKind]
    ) -> PracticeSettingsValidation {
        var validation = PracticeSettingsValidation()
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

        // A separation that no longer has the targeted stem is reported, not
        // silently swapped: practising a different part without being told is
        // worse than being told the part is gone.
        if let target, !availableStems.contains(target) {
            validation.missingTarget = target
            self.target = nil
        }
        if target == nil {
            target = availableStems.contains(.vocals) ? .vocals : availableStems.first
        }
        validation.replacementTarget = validation.missingTarget == nil ? nil : target

        // Levels for stems this separation does not have are kept, not dropped:
        // separating the same song 4-stem and then 6-stem again should find the
        // guitar fader where it was left. Only keys that name no stem at all go.
        stemLevels = stemLevels.reduce(into: [:]) { result, entry in
            guard StemKind(rawValue: entry.key) != nil else { return }
            result[entry.key] = entry.value.isFinite ? min(1, max(0, entry.value)) : 1
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
            return validation
        }
        loopStart = range.start
        loopEnd = range.end
        return validation
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

/// Reads and writes a song's practice state as `practice.json` beside the song.
///
/// It knows nothing about `UserDefaults` any more, and nothing about track IDs:
/// practice state belongs to the song, so it is addressed by the song's storage
/// and outlives any particular separation of it.
struct PracticeSettingsStore: Sendable {
    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Library"
    )

    init() {}

    /// A damaged or half-written file reads as "no saved practice state", which
    /// costs the user their settings for this song and nothing more. The
    /// alternative — refusing to open the song — is worse for a file whose whole
    /// purpose is convenience.
    func load(from storage: SongStorage) -> SongPracticeSettings {
        storage.read(SongPracticeSettings.self, from: SongStorage.practiceFilename)
            ?? SongPracticeSettings()
    }

    func save(_ settings: SongPracticeSettings, to storage: SongStorage) {
        do {
            try storage.write(settings, to: SongStorage.practiceFilename)
        } catch {
            logger.error(
                "Could not save practice settings: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func reset(in storage: SongStorage) {
        storage.remove(SongStorage.practiceFilename)
    }
}
