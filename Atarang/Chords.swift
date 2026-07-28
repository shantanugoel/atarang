import Foundation

/// The twelve pitch classes, and how they are spelled.
///
/// Spelling is not cosmetic. A guitarist reading "A♯" in the key of F has to
/// translate it back to B♭ before their hand knows what to do, so the key
/// decides which set of names is used and the detector's integers never reach
/// the screen untranslated.
enum PitchClass {
    static let sharpNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let flatNames = ["C", "D♭", "D", "E♭", "E", "F", "G♭", "G", "A♭", "A", "B♭", "B"]

    static func normalized(_ value: Int) -> Int {
        let wrapped = value % 12
        return wrapped < 0 ? wrapped + 12 : wrapped
    }

    static func name(_ value: Int, preferringFlats: Bool) -> String {
        let index = normalized(value)
        return preferringFlats ? flatNames[index] : sharpNames[index]
    }

    /// What VoiceOver says. "C sharp" rather than "C♯", which is read as
    /// "C number sign" by some voices.
    static func spokenName(_ value: Int, preferringFlats: Bool) -> String {
        name(value, preferringFlats: preferringFlats)
            .replacingOccurrences(of: "♯", with: " sharp")
            .replacingOccurrences(of: "♭", with: " flat")
    }
}

/// A semantic chord formula, independent from the detector's vocabulary.
///
/// Imported charts need a much wider language than audio detection should ever
/// attempt. Keeping the formula's intervals and canonical notation together
/// lets import, transposition, simplification, comparison, and VoiceOver stay
/// honest without adding every formula to the detector state machine.
struct ChordQuality: Codable, Hashable, Sendable, Identifiable {
    enum Base: String, Codable, Sendable {
        case major, minor, suspended, power, diminished, augmented
    }

    var base: Base
    /// Canonical semitone intervals above the root, including the root.
    var intervals: [Int]
    /// Canonical chart suffix. It is notation, not a detector label.
    var symbol: String
    var spokenName: String

    var id: String { "\(base.rawValue):\(intervals.map(String.init).joined(separator: ",")):\(symbol)" }

    init(base: Base, intervals: [Int], symbol: String, spokenName: String) {
        self.base = base
        self.intervals = Array(Set(intervals.map(PitchClass.normalized))).sorted()
        self.symbol = symbol
        self.spokenName = spokenName
    }

    static let major = Self(base: .major, intervals: [0, 4, 7], symbol: "", spokenName: "major")
    static let minor = Self(base: .minor, intervals: [0, 3, 7], symbol: "m", spokenName: "minor")
    static let dominantSeventh = Self(base: .major, intervals: [0, 4, 7, 10], symbol: "7", spokenName: "seven")
    static let minorSeventh = Self(base: .minor, intervals: [0, 3, 7, 10], symbol: "m7", spokenName: "minor seven")
    static let majorSeventh = Self(base: .major, intervals: [0, 4, 7, 11], symbol: "maj7", spokenName: "major seven")
    static let suspendedSecond = Self(base: .suspended, intervals: [0, 2, 7], symbol: "sus2", spokenName: "sus two")
    static let suspendedFourth = Self(base: .suspended, intervals: [0, 5, 7], symbol: "sus4", spokenName: "sus four")
    static let diminished = Self(base: .diminished, intervals: [0, 3, 6], symbol: "dim", spokenName: "diminished")
    static let diminishedSeventh = Self(base: .diminished, intervals: [0, 3, 6, 9], symbol: "dim7", spokenName: "diminished seven")
    static let augmented = Self(base: .augmented, intervals: [0, 4, 8], symbol: "aug", spokenName: "augmented")
    static let halfDiminished = Self(base: .diminished, intervals: [0, 3, 6, 10], symbol: "m7♭5", spokenName: "minor seven flat five")
    static let power = Self(base: .power, intervals: [0, 7], symbol: "5", spokenName: "five")
    static let sixth = Self(base: .major, intervals: [0, 4, 7, 9], symbol: "6", spokenName: "six")
    static let minorSixth = Self(base: .minor, intervals: [0, 3, 7, 9], symbol: "m6", spokenName: "minor six")
    static let ninth = Self(base: .major, intervals: [0, 4, 7, 10, 2], symbol: "9", spokenName: "nine")
    static let majorNinth = Self(base: .major, intervals: [0, 4, 7, 11, 2], symbol: "maj9", spokenName: "major nine")
    static let minorNinth = Self(base: .minor, intervals: [0, 3, 7, 10, 2], symbol: "m9", spokenName: "minor nine")
    static let addSecond = Self(base: .major, intervals: [0, 2, 4, 7], symbol: "add2", spokenName: "add two")
    static let addFourth = Self(base: .major, intervals: [0, 4, 5, 7], symbol: "add4", spokenName: "add four")
    static let addNinth = Self(base: .major, intervals: [0, 2, 4, 7], symbol: "add9", spokenName: "add nine")
    static let flatFifth = Self(base: .major, intervals: [0, 4, 6], symbol: "♭5", spokenName: "flat five")
    static let sharpFifth = Self(base: .major, intervals: [0, 4, 8], symbol: "♯5", spokenName: "sharp five")

    static let allCases: [Self] = [
        .major, .minor, .dominantSeventh, .minorSeventh, .majorSeventh,
        .suspendedSecond, .suspendedFourth, .sixth, .minorSixth, .ninth,
        .majorNinth, .minorNinth, .addSecond, .addFourth, .addNinth,
        .diminished, .diminishedSeventh, .halfDiminished, .augmented,
        .flatFifth, .sharpFifth, .power,
    ]

    /// Deliberately small: representable does not imply safely detectable.
    static let detectable: [Self] = [
        .major, .minor, .dominantSeventh, .minorSeventh,
        .majorSeventh, .suspendedFourth, .diminished,
    ]
    static let triads: [Self] = [.major, .minor]

    var prior: Double {
        if self == .major || self == .minor || self == .power { return 0 }
        if self == .suspendedFourth { return -0.02 }
        if self == .diminished { return -0.04 }
        return -0.03
    }

    /// The closest musically honest stable base used by Simple mode.
    var triad: Self {
        switch base {
        case .major: .major
        case .minor: .minor
        case .power: .power
        case .diminished: .diminished
        case .augmented: .augmented
        case .suspended: self
        }
    }
}

/// One chord: a root, a quality, and — when the bass says so — the note under
/// it.
struct Chord: Codable, Hashable, Sendable {
    /// Pitch class, 0 = C.
    var root: Int
    var quality: ChordQuality
    /// The bass pitch class when it is a chord tone other than the root, which
    /// is what makes this a slash chord. `nil` means the bass is on the root or
    /// was not clear enough to claim.
    var bass: Int?

    init(root: Int, quality: ChordQuality, bass: Int? = nil) {
        self.root = PitchClass.normalized(root)
        self.quality = quality
        self.bass = bass.map(PitchClass.normalized)
    }

    var pitchClasses: [Int] {
        quality.intervals.map { PitchClass.normalized(root + $0) }
    }

    func transposed(by semitones: Int) -> Chord {
        Chord(
            root: root + semitones,
            quality: quality,
            bass: bass.map { $0 + semitones }
        )
    }

    func symbol(preferringFlats: Bool) -> String {
        let base = PitchClass.name(root, preferringFlats: preferringFlats) + quality.symbol
        guard let bass, bass != root else { return base }
        return base + "/" + PitchClass.name(bass, preferringFlats: preferringFlats)
    }

    func spokenName(preferringFlats: Bool) -> String {
        var value = PitchClass.spokenName(root, preferringFlats: preferringFlats)
            + " " + quality.spokenName
        if let bass, bass != root {
            value += " over " + PitchClass.spokenName(bass, preferringFlats: preferringFlats)
        }
        return value
    }
}

/// A key, as the decoder uses it and as the screen states it.
struct MusicalKey: Codable, Hashable, Sendable {
    var tonic: Int
    var isMinor: Bool

    init(tonic: Int, isMinor: Bool) {
        self.tonic = PitchClass.normalized(tonic)
        self.isMinor = isMinor
    }

    /// Which spelling this key uses. The circle of fifths, read as the list of
    /// keys whose signatures are written with flats.
    var prefersFlats: Bool {
        let flatMajors = [5, 10, 3, 8, 1, 6]
        let flatMinors = flatMajors.map { PitchClass.normalized($0 - 3) }
        return isMinor ? flatMinors.contains(tonic) : flatMajors.contains(tonic)
    }

    var name: String {
        PitchClass.name(tonic, preferringFlats: prefersFlats)
            + (isMinor ? " minor" : " major")
    }

    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: tonic + semitones, isMinor: isMinor)
    }

    /// The scale degrees, as pitch classes.
    var scalePitchClasses: [Int] {
        let steps = isMinor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        return steps.map { PitchClass.normalized(tonic + $0) }
    }

    /// The chords this key is built from, used to condition the decoder's
    /// transitions rather than to restrict what it may print.
    var diatonicChords: [Chord] {
        let qualities: [ChordQuality] = isMinor
            ? [.minor, .diminished, .major, .minor, .minor, .major, .major]
            : [.major, .minor, .minor, .major, .major, .minor, .diminished]
        return zip(scalePitchClasses, qualities).map { Chord(root: $0, quality: $1) }
    }

    /// True when every note of the chord belongs to the key. Deliberately about
    /// the *notes* rather than the seven triads: a G7 in C is not one of the
    /// diatonic triads and is not remotely out of key.
    func contains(_ chord: Chord) -> Bool {
        let scale = Set(scalePitchClasses)
        return chord.pitchClasses.allSatisfy(scale.contains)
    }
}

/// One stretch of one chord.
///
/// Boundaries are beat times from the Phase 7 grid, in source-song seconds like
/// every other timestamp in the app, so they stay correct under speed and pitch
/// changes.
struct ChordSegment: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    /// `nil` is no chord: silence, an unpitched fill, or material the templates
    /// could not fit. It is a real answer and is printed as one.
    var chord: Chord?
    /// How well the templates fitted, 0 to 1. A hand correction is certain by
    /// definition and carries 1.
    var confidence: Double
    /// Set by any correction. Re-analysis must never overwrite a chord the user
    /// has fixed — they played the song and the detector did not.
    var isUserEdited = false
    /// What was actually heard, when `chord` has been simplified for display.
    ///
    /// Display-only and deliberately outside `CodingKeys`: simplification is a
    /// lens the Chords stage puts over the stored chart, and writing the lens
    /// into `chords.json` would turn a preference into a fact about the song.
    var detected: Chord?

    private enum CodingKeys: String, CodingKey {
        case id, start, end, chord, confidence, isUserEdited
    }

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        chord: Chord?,
        confidence: Double = 0,
        isUserEdited: Bool = false,
        detected: Chord? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.chord = chord
        self.confidence = confidence
        self.isUserEdited = isUserEdited
        self.detected = detected
    }

    var duration: TimeInterval { max(0, end - start) }

    /// True when what is printed is not what was heard.
    var isSimplified: Bool {
        guard let detected else { return false }
        return detected != chord
    }

    func symbol(preferringFlats: Bool) -> String {
        chord?.symbol(preferringFlats: preferringFlats) ?? "N.C."
    }
}

/// One bar of the chart.
struct ChordBar: Identifiable, Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        /// The segment this came from, so a correction made from the grid can
        /// find its way back to the right chord.
        let id: UUID
        let chord: Chord?
        /// What was heard, when `chord` is a simplification of it.
        let detected: Chord?
        let start: TimeInterval
        /// Which beat of the bar the chord lands on, 0 for the downbeat.
        let beatOffset: Int
        let confidence: Double
        let isUserEdited: Bool
        /// True when this chord began in an earlier bar and is still being
        /// held. What "merge repeated chords" acts on: the same symbol printed
        /// four times in a row says nothing the first one did not.
        let isContinuation: Bool

        var isSimplified: Bool {
            guard let detected else { return false }
            return detected != chord
        }
    }

    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    var entries: [Entry]

    /// The bar number a musician would count, which is one-based.
    var number: Int { id + 1 }
}

/// Everything the app knows about a song's harmony.
struct SongChords: AnalysisArtifact, Equatable {
    /// Version 2 adopts semantic chord formulas. This pre-release schema
    /// intentionally invalidates development-era enum-backed chord artifacts.
    static let currentAnalysisVersion = 2
    static var filename: String { SongStorage.chordsFilename }

    /// Below this the chart is shown and said to be a guess, and nothing acts
    /// on it.
    static let reliableConfidence = 0.5
    /// A chord below this is dimmed. It is still the best answer available, and
    /// hiding it would leave a hole where the user needs *something* to play.
    static let confidentSegment = 0.5
    /// The share of the song the templates may fail to fit before the chart
    /// says so outright.
    static let unmodelledShareLimit = 0.35

    var analysisVersion = Self.currentAnalysisVersion
    var segments: [ChordSegment] = []
    var key: MusicalKey?
    /// How well the whole analysis fitted, 0 to 1.
    var confidence: Double = 0
    /// Which stems the analysis mix was built from. A chart taken off isolated
    /// bass, guitar, and piano is stronger evidence than one taken off a single
    /// instrumental stem, and this is what lets the interface say which.
    var sourceStems: [StemKind] = []
    var updatedAt = Date()

    init(
        segments: [ChordSegment] = [],
        key: MusicalKey? = nil,
        confidence: Double = 0,
        sourceStems: [StemKind] = []
    ) {
        self.segments = segments
        self.key = key
        self.confidence = confidence
        self.sourceStems = sourceStems
    }

    // MARK: - Shape

    var isEmpty: Bool { segments.isEmpty }

    var isReliable: Bool {
        !isEmpty && (confidence >= Self.reliableConfidence || hasUserEdits)
    }

    var hasUserEdits: Bool { segments.contains(where: \.isUserEdited) }

    var prefersFlats: Bool { key?.prefersFlats ?? false }

    /// The share of the song that is either no-chord or a chord the templates
    /// barely fitted. This is the number behind saying "there is a lot here
    /// Atarang could not model" instead of printing confident nonsense.
    var unmodelledFraction: Double {
        let total = segments.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let unmodelled = segments
            .filter { $0.chord == nil || $0.confidence < Self.confidentSegment }
            .filter { !$0.isUserEdited }
            .reduce(0) { $0 + $1.duration }
        return unmodelled / total
    }

    var templatesStruggled: Bool { unmodelledFraction > Self.unmodelledShareLimit }

    /// The chords this song uses, most-played first. Phase 9 builds the
    /// fretboard strip on it; the chart header already uses it to say how many
    /// shapes the song asks for.
    var vocabulary: [Chord] {
        var totals: [Chord: TimeInterval] = [:]
        for segment in segments {
            guard let chord = segment.chord else { continue }
            totals[chord, default: 0] += segment.duration
        }
        return totals.sorted { $0.value > $1.value }.map(\.key)
    }

    // MARK: - Lookup

    func index(at time: TimeInterval) -> Int? {
        guard !segments.isEmpty else { return nil }
        var low = 0
        var high = segments.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            if segments[middle].start <= time {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        // Past the end of the last segment is genuinely no answer, not the last
        // chord held forever: a song that ends on silence should print nothing.
        guard let result else { return nil }
        return time < segments[result].end ? result : nil
    }

    func segment(at time: TimeInterval) -> ChordSegment? {
        index(at: time).map { segments[$0] }
    }

    /// The next chord that is different from the one sounding now, which is
    /// what a preview is for: "the same chord again" is not news.
    func nextChange(after time: TimeInterval) -> ChordSegment? {
        let current = segment(at: time)?.chord
        return segments.first { $0.start > time && $0.chord != current }
    }

    /// The chart as it should be read while the audio is transposed.
    func transposed(by semitones: Int) -> SongChords {
        guard semitones != 0 else { return self }
        var result = self
        result.segments = segments.map { segment in
            var moved = segment
            moved.chord = segment.chord?.transposed(by: semitones)
            moved.detected = segment.detected?.transposed(by: semitones)
            return moved
        }
        result.key = key?.transposed(by: semitones)
        return result
    }

    // MARK: - Bars

    /// The chart laid out in bars, using the beat grid's own downbeats.
    ///
    /// Returns nothing when there is no reliable grid: a bar grid drawn on
    /// guessed bar lines would be a picture of a song that was never played.
    /// The ribbon view is what covers that case.
    func bars(using grid: BeatGrid, duration: TimeInterval) -> [ChordBar] {
        let downbeats = grid.downbeatTimes
        guard grid.isReliable, downbeats.count > 1, !segments.isEmpty else { return [] }
        let beatTimes = grid.beats.map(\.time)
        var bars: [ChordBar] = []
        bars.reserveCapacity(downbeats.count)

        for (index, start) in downbeats.enumerated() {
            let end = index + 1 < downbeats.count
                ? downbeats[index + 1]
                : min(duration, grid.beats.last?.time ?? duration)
            guard end > start else { continue }
            var entries: [ChordBar.Entry] = []
            for segment in segments where segment.end > start && segment.start < end {
                let entryStart = max(segment.start, start)
                let beatOffset = beatTimes.filter { $0 >= start && $0 < entryStart - 0.001 }.count
                entries.append(
                    ChordBar.Entry(
                        id: segment.id,
                        chord: segment.chord,
                        detected: segment.detected,
                        start: entryStart,
                        beatOffset: beatOffset,
                        confidence: segment.confidence,
                        isUserEdited: segment.isUserEdited,
                        isContinuation: segment.start < start - 0.001
                    )
                )
            }
            bars.append(ChordBar(id: index, start: start, end: end, entries: entries))
        }
        return bars
    }

    // MARK: - Correction

    /// Replaces one segment's chord and records that a person did it.
    mutating func correct(_ id: UUID, to chord: Chord?) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].chord = chord
        segments[index].confidence = 1
        segments[index].isUserEdited = true
        updatedAt = Date()
    }

    /// Writes one segment over whatever occupied its range, splitting the
    /// neighbours rather than deleting them.
    mutating func apply(_ edit: ChordSegment) {
        var updated: [ChordSegment] = []
        for segment in segments {
            if segment.end <= edit.start || segment.start >= edit.end {
                updated.append(segment)
                continue
            }
            if segment.start < edit.start {
                var head = segment
                head.end = edit.start
                updated.append(head)
            }
            if segment.end > edit.end {
                var tail = segment
                tail.id = UUID()
                tail.start = edit.end
                updated.append(tail)
            }
        }
        updated.append(edit)
        segments = updated.sorted { $0.start < $1.start }
        updatedAt = Date()
    }

    /// What a finished re-analysis is allowed to do to what is already stored.
    ///
    /// Unlike the beat grid, a corrected chart is not all-or-nothing: someone
    /// who fixed the bridge should still get a better verse out of a rerun. So
    /// the fresh analysis wins everywhere except the ranges the user has
    /// touched, which are written back over it.
    func resolvingReanalysis(
        _ fresh: SongChords,
        duration: TimeInterval
    ) -> SongChords {
        let edits = segments.filter(\.isUserEdited)
        guard !edits.isEmpty else { return fresh }
        var result = fresh
        for edit in edits { result.apply(edit) }
        result.sanitize(duration: duration)
        return result
    }

    // MARK: - Editing

    mutating func sanitize(duration: TimeInterval) {
        confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        let limit = duration.isFinite ? max(0, duration) : 0
        var cleaned: [ChordSegment] = []
        for var segment in segments.sorted(by: { $0.start < $1.start }) {
            guard segment.start.isFinite, segment.end.isFinite else { continue }
            segment.start = min(max(0, segment.start), limit)
            segment.end = min(max(segment.start, segment.end), limit)
            segment.confidence = segment.confidence.isFinite
                ? min(1, max(0, segment.confidence))
                : 0
            guard segment.duration > 0.01 else { continue }
            // No overlaps: the later segment wins its own start, because that
            // is what a correction written over a detected chord means.
            if var last = cleaned.last, last.end > segment.start {
                last.end = segment.start
                if last.duration > 0.01 {
                    cleaned[cleaned.count - 1] = last
                } else {
                    cleaned.removeLast()
                }
            }
            // Two neighbouring stretches of the same chord are one chord. The
            // decoder emits per beat, so without this a bar of C is four
            // segments and every display has to merge them itself.
            if let last = cleaned.last,
               last.chord == segment.chord,
               // Two simplified stretches that print the same symbol but came
               // from different chords stay apart: merging them would make the
               // reveal lie about the second half.
               last.detected == segment.detected,
               last.isUserEdited == segment.isUserEdited,
               abs(last.end - segment.start) < 0.01 {
                let weight = last.duration + segment.duration
                cleaned[cleaned.count - 1].end = segment.end
                cleaned[cleaned.count - 1].confidence = weight > 0
                    ? (last.confidence * last.duration + segment.confidence * segment.duration) / weight
                    : last.confidence
                continue
            }
            cleaned.append(segment)
        }
        segments = cleaned
    }
}
