import Foundation

/// How much of the detected harmony to print.
///
/// This is a lens, not an edit: the stored chart never changes, and every level
/// can be undone by choosing another. It exists because a chart is only useful
/// if the person holding the guitar can play it — a page of maj7 and slash
/// chords is an accurate description of a song and a useless instruction to a
/// beginner.
enum ChordComplexity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Everything that was heard.
    case full
    /// Sevenths reduced to the triads underneath them.
    case simple
    /// Reduced again, to shapes that exist in open position.
    case beginner
    /// Root and fifth. What a distorted guitar plays anyway, and what makes a
    /// fast song possible for one hand.
    case power

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .simple: "Simple"
        case .beginner: "Beginner"
        case .power: "Power"
        }
    }

    var detail: String {
        switch self {
        case .full: "Every chord as it was heard."
        case .simple: "Sevenths become the plain triad underneath."
        case .beginner: "Open-position shapes wherever one will do."
        case .power: "Root and fifth only."
        }
    }
}

/// Everything the Chords and Sheet stages apply on top of the stored chart.
///
/// One value, passed down, so the two stages cannot disagree about what the
/// user asked for.
struct ChordDisplayOptions: Equatable, Sendable {
    var complexity: ChordComplexity = .full
    /// Drops the note under the chord, leaving the grip.
    var hidesInversions = false
    /// Stops printing a chord that is still being held from the bar before.
    var mergesRepeatedChords = false
    /// Removes chords shorter than a beat — the ones a chart cannot really
    /// instruct anyone to play.
    var hidesPassingChords = false
    /// Where the capo is, 0 for none. Shapes are printed relative to it.
    var capo = 0

    static let none = ChordDisplayOptions()

    var isSimplifying: Bool {
        complexity != .full || hidesInversions || hidesPassingChords
    }

    var changesAnything: Bool {
        isSimplifying || mergesRepeatedChords || capo != 0
    }
}

/// What a chord became, and whether it could become it.
struct ChordSimplification: Equatable, Sendable {
    /// The chart as it should be read, with `detected` recording what each
    /// simplified chord actually was.
    var chords: SongChords
    /// The chords no level could make playable in open position. Named so the
    /// interface can say which, rather than quietly printing a barre chord in
    /// a chart the user asked to be beginner-friendly.
    var unplayable: [Chord] = []

    var isComplete: Bool { unplayable.isEmpty }
}

/// Turning a chart into something a pair of hands can do.
enum ChordPlayability {
    /// The furthest a capo is worth suggesting. Past the seventh fret the frets
    /// are too close together for most hands and the guitar starts sounding
    /// like a mandolin.
    static let maximumCapo = 7

    // MARK: - Simplification

    /// Applies a set of display options to a chart.
    ///
    /// `beatDuration` is only needed for the passing-chord filter; without a
    /// beat grid there is no such thing as "shorter than a beat", so that
    /// option simply does nothing.
    static func apply(
        _ options: ChordDisplayOptions,
        to chords: SongChords,
        duration: TimeInterval,
        beatDuration: TimeInterval? = nil
    ) -> ChordSimplification {
        guard options.changesAnything else {
            return ChordSimplification(chords: chords)
        }
        var result = chords
        var unplayable: [Chord] = []

        if options.hidesPassingChords, let beatDuration, beatDuration > 0 {
            result.segments = removingPassingChords(
                result.segments,
                shorterThan: beatDuration * 0.75
            )
        }

        result.segments = result.segments.map { segment in
            guard let chord = segment.chord else { return segment }
            var moved = segment
            var simplified = chord
            if options.hidesInversions { simplified.bass = nil }
            switch options.complexity {
            case .full:
                break
            case .simple:
                simplified = Chord(root: simplified.root, quality: simplified.quality.triad)
            case .beginner:
                let (chord, wasFound) = beginnerChord(for: simplified, capo: options.capo)
                simplified = chord
                if !wasFound, !unplayable.contains(chord) { unplayable.append(chord) }
            case .power:
                simplified = Chord(root: simplified.root, quality: .power)
            }
            if simplified != chord {
                moved.chord = simplified
                moved.detected = chord
            }
            return moved
        }
        result.sanitize(duration: duration)
        // Capo last, and on its own: the shape a player grips is the sounding
        // chord moved down by the capo, and doing it before simplification
        // would have the beginner search looking for open shapes in the wrong
        // key.
        if options.capo != 0 {
            result = result.transposed(by: -options.capo)
        }
        return ChordSimplification(chords: result, unplayable: unplayable)
    }

    /// The nearest chord with an open-position shape, and whether one was
    /// found.
    ///
    /// The substitutions are the ones a teacher makes: a seventh is its triad,
    /// a diminished chord is the minor triad inside it, a sus4 is the major
    /// chord it resolves to. When even that has no open shape the chord is
    /// returned unchanged and reported — telling the user their song needs an
    /// F is better than printing an E and letting them wonder why it sounds
    /// wrong.
    static func beginnerChord(for chord: Chord, capo: Int = 0) -> (chord: Chord, wasFound: Bool) {
        let candidates: [Chord] = [
            chord,
            Chord(root: chord.root, quality: chord.quality.triad),
            Chord(
                root: chord.root,
                quality: chord.quality.base == .minor || chord.quality.base == .diminished
                    ? .minor
                    : .major
            ),
            Chord(root: chord.root, quality: .power)
        ]
        for candidate in candidates where ChordShapes.isOpen(candidate.transposed(by: -capo)) {
            return (candidate, true)
        }
        return (Chord(root: chord.root, quality: chord.quality.triad), false)
    }

    /// Absorbs anything shorter than `limit` into the chord before it.
    ///
    /// A passing chord is real — it was played — but a chart is an instruction,
    /// and an instruction to change chord for a fifth of a second is one nobody
    /// can follow. The first segment has nothing before it to absorb into, so it
    /// survives whatever its length.
    static func removingPassingChords(
        _ segments: [ChordSegment],
        shorterThan limit: TimeInterval
    ) -> [ChordSegment] {
        var result: [ChordSegment] = []
        for segment in segments {
            // A correction is never a passing chord: the user said this is what
            // is played there.
            if segment.duration < limit, !segment.isUserEdited, var previous = result.last {
                previous.end = segment.end
                result[result.count - 1] = previous
                continue
            }
            result.append(segment)
        }
        return result
    }

    // MARK: - Capo

    /// What a capo would do to a song.
    struct CapoSuggestion: Equatable, Sendable, Identifiable {
        var fret: Int
        /// The share of the song, by time, that lands on an open shape.
        var openShare: Double
        /// How easy the whole chart becomes, 0 to 1.
        var score: Double
        /// The shapes the player would grip, most-played first.
        var shapes: [Chord]

        var id: Int { fret }

        var summary: String {
            let percent = Int((openShare * 100).rounded())
            if fret == 0 {
                return "No capo — \(percent)% of this song is already open shapes."
            }
            return "Capo \(fret) — \(percent)% of this song becomes open shapes."
        }
    }

    /// Scores every capo position and returns them best first.
    ///
    /// Weighted by how long each chord is played rather than by how many there
    /// are: a song with one bar of B♭ and thirty of G is a G song, and a capo
    /// that fixes the B♭ at the cost of the G is the wrong answer.
    static func capoSuggestions(for chords: SongChords) -> [CapoSuggestion] {
        var weights: [Chord: TimeInterval] = [:]
        for segment in chords.segments {
            guard let chord = segment.chord else { continue }
            weights[Chord(root: chord.root, quality: chord.quality), default: 0] += segment.duration
        }
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [] }

        return (0...maximumCapo).map { capo in
            var ease: Double = 0
            var openTime: TimeInterval = 0
            for (chord, time) in weights {
                let shape = chord.transposed(by: -capo)
                ease += ChordShapes.ease(of: shape) * time
                if ChordShapes.isOpen(shape) { openTime += time }
            }
            // A capo is a thing to fetch and fit, so it has to earn its place:
            // an eighth of a fret's worth of ease, which is less than one
            // barre chord turning into an open one and more than nothing.
            let penalty = Double(capo) * 0.012
            return CapoSuggestion(
                fret: capo,
                openShare: openTime / total,
                score: max(0, ease / total - penalty),
                shapes: weights
                    .sorted { $0.value > $1.value }
                    .map { $0.key.transposed(by: -capo) }
            )
        }
        .sorted { $0.score > $1.score }
    }

    static func bestCapo(for chords: SongChords) -> CapoSuggestion? {
        capoSuggestions(for: chords).first
    }

    // MARK: - Playable keys

    /// A key the song could be shifted into, and what it would cost.
    struct KeyShift: Equatable, Sendable, Identifiable {
        /// Semitones to shift the audio by.
        var semitones: Int
        var key: MusicalKey?
        var score: Double
        var openShare: Double
        var shapes: [Chord]

        var id: Int { semitones }

        var title: String {
            let shift = StudioFormat.semitones(Float(semitones))
            guard let key else {
                return semitones == 0 ? "Original pitch" : shift
            }
            return semitones == 0 ? "\(key.name) — original" : "\(key.name) · \(shift)"
        }
    }

    /// The best keys to shift the *audio* into so the chart becomes playable.
    ///
    /// The other half of the capo answer, and the one that works for
    /// instruments a capo does not fit. Restricted to ±6 semitones because
    /// beyond that the time-pitch unit is audibly working and the song stops
    /// sounding like itself long before the chart gets easier.
    static func playableKeys(
        for chords: SongChords,
        limit: Int = 6
    ) -> [KeyShift] {
        var weights: [Chord: TimeInterval] = [:]
        for segment in chords.segments {
            guard let chord = segment.chord else { continue }
            weights[Chord(root: chord.root, quality: chord.quality), default: 0] += segment.duration
        }
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [] }

        return (-limit...limit).map { semitones in
            var ease: Double = 0
            var openTime: TimeInterval = 0
            for (chord, time) in weights {
                let shifted = chord.transposed(by: semitones)
                ease += ChordShapes.ease(of: shifted) * time
                if ChordShapes.isOpen(shifted) { openTime += time }
            }
            // Shifting the audio costs something real — the further it goes the
            // more the stems smear — so a shift has to beat the original by
            // more than rounding to be worth offering.
            let penalty = Double(abs(semitones)) * 0.015
            return KeyShift(
                semitones: semitones,
                key: chords.key?.transposed(by: semitones),
                score: max(0, ease / total - penalty),
                openShare: openTime / total,
                shapes: weights
                    .sorted { $0.value > $1.value }
                    .map { $0.key.transposed(by: semitones) }
            )
        }
        .sorted { $0.score > $1.score }
    }
}
