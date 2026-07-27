import XCTest
@testable import Atarang

final class ChordModelTests: XCTestCase {
    private func chord(_ root: Int, _ quality: ChordQuality = .major) -> Chord {
        Chord(root: root, quality: quality)
    }

    private func chords(_ segments: [ChordSegment], duration: TimeInterval = 60) -> SongChords {
        var value = SongChords(segments: segments)
        value.sanitize(duration: duration)
        return value
    }

    // MARK: - Spelling

    func testAChordIsSpelledForTheKeyItIsIn() {
        // The same pitch class, twice, because a guitarist reading "A♯" in F has
        // to translate it before their hand knows what to do.
        XCTAssertEqual(chord(10).symbol(preferringFlats: true), "B♭")
        XCTAssertEqual(chord(10).symbol(preferringFlats: false), "A♯")
    }

    func testQualitiesAreWrittenTheWayChartsWriteThem() {
        XCTAssertEqual(chord(0, .major).symbol(preferringFlats: false), "C")
        XCTAssertEqual(chord(9, .minor).symbol(preferringFlats: false), "Am")
        XCTAssertEqual(chord(7, .dominantSeventh).symbol(preferringFlats: false), "G7")
        XCTAssertEqual(chord(5, .majorSeventh).symbol(preferringFlats: false), "Fmaj7")
        XCTAssertEqual(chord(2, .suspendedFourth).symbol(preferringFlats: false), "Dsus4")
    }

    func testABassNoteThatIsNotTheRootMakesASlashChord() {
        let chord = Chord(root: 0, quality: .major, bass: 4)

        XCTAssertEqual(chord.symbol(preferringFlats: false), "C/E")
        // A bass on the root is not news, and printing "C/C" everywhere would
        // make a chart unreadable for no information.
        XCTAssertEqual(Chord(root: 0, quality: .major, bass: 0).symbol(preferringFlats: false), "C")
    }

    func testTransposingMovesTheBassWithTheRoot() {
        let moved = Chord(root: 0, quality: .major, bass: 4).transposed(by: 2)

        XCTAssertEqual(moved.root, 2)
        XCTAssertEqual(moved.bass, 6)
    }

    func testTransposingWrapsAroundTheOctave() {
        XCTAssertEqual(chord(10).transposed(by: 3).root, 1)
        XCTAssertEqual(chord(1).transposed(by: -3).root, 10)
    }

    // MARK: - Keys

    func testFlatKeysAreSpelledWithFlats() {
        XCTAssertTrue(MusicalKey(tonic: 5, isMinor: false).prefersFlats)
        XCTAssertTrue(MusicalKey(tonic: 2, isMinor: true).prefersFlats)
        XCTAssertFalse(MusicalKey(tonic: 7, isMinor: false).prefersFlats)
        XCTAssertEqual(MusicalKey(tonic: 10, isMinor: false).name, "B♭ major")
    }

    func testAKeyContainsAChordWhenItContainsEveryNoteOfIt() {
        let cMajor = MusicalKey(tonic: 0, isMinor: false)

        XCTAssertTrue(cMajor.contains(chord(7, .dominantSeventh)))
        XCTAssertTrue(cMajor.contains(chord(9, .minor)))
        // E major has a G♯, which C major does not.
        XCTAssertFalse(cMajor.contains(chord(4, .major)))
    }

    func testTheDiatonicChordsOfAMajorKeyAreTheOnesEveryoneLearns() {
        let symbols = MusicalKey(tonic: 0, isMinor: false)
            .diatonicChords
            .map { $0.symbol(preferringFlats: false) }

        XCTAssertEqual(symbols, ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
    }

    // MARK: - Segments

    func testNeighbouringStretchesOfTheSameChordBecomeOne() {
        // The decoder emits one segment per beat; without merging, a bar of C is
        // four segments and every display has to merge them itself.
        let merged = chords([
            ChordSegment(start: 0, end: 0.5, chord: chord(0), confidence: 0.8),
            ChordSegment(start: 0.5, end: 1, chord: chord(0), confidence: 0.6),
            ChordSegment(start: 1, end: 1.5, chord: chord(5), confidence: 0.9),
        ])

        XCTAssertEqual(merged.segments.count, 2)
        XCTAssertEqual(merged.segments[0].end, 1)
        XCTAssertEqual(merged.segments[0].confidence, 0.7, accuracy: 0.0001)
    }

    func testSegmentsAreClampedIntoTheSongAndZeroLengthOnesGo() {
        let cleaned = chords(
            [
                ChordSegment(start: -3, end: 2, chord: chord(0)),
                ChordSegment(start: 4, end: 4, chord: chord(5)),
                ChordSegment(start: 8, end: 40, chord: chord(7)),
            ],
            duration: 10
        )

        XCTAssertEqual(cleaned.segments.first?.start, 0)
        XCTAssertEqual(cleaned.segments.last?.end, 10)
        XCTAssertEqual(cleaned.segments.count, 2)
    }

    func testTheChordAtATimeIsTheOneSounding() {
        let value = chords([
            ChordSegment(start: 0, end: 2, chord: chord(0)),
            ChordSegment(start: 2, end: 4, chord: chord(5)),
        ])

        XCTAssertEqual(value.segment(at: 1)?.chord, chord(0))
        XCTAssertEqual(value.segment(at: 2)?.chord, chord(5))
        // Past the last chord is no chord, not the last one held forever.
        XCTAssertNil(value.segment(at: 5))
    }

    func testTheNextChangeSkipsTheSameChordAgain() {
        let value = chords([
            ChordSegment(start: 0, end: 2, chord: chord(0)),
            ChordSegment(start: 2, end: 4, chord: nil),
            ChordSegment(start: 4, end: 6, chord: chord(5)),
        ])

        XCTAssertEqual(value.nextChange(after: 0.5)?.chord, nil)
        XCTAssertEqual(value.nextChange(after: 2.5)?.chord, chord(5))
    }

    func testTheWholeChartTransposesWithTheAudio() {
        let value = chords([
            ChordSegment(start: 0, end: 2, chord: chord(0)),
            ChordSegment(start: 2, end: 4, chord: chord(9, .minor)),
        ])

        let up = value.transposed(by: 2)

        XCTAssertEqual(up.segments[0].chord, chord(2))
        XCTAssertEqual(up.segments[1].chord, chord(11, .minor))
        XCTAssertEqual(up.transposed(by: -2), value)
    }

    func testTransposingCarriesTheKeyWithIt() {
        var value = chords([ChordSegment(start: 0, end: 2, chord: chord(0))])
        value.key = MusicalKey(tonic: 0, isMinor: false)

        XCTAssertEqual(value.transposed(by: 5).key, MusicalKey(tonic: 5, isMinor: false))
    }

    // MARK: - Bars

    func testTheChartIsLaidOutOnTheGridsOwnBars() {
        let grid = BeatGrid.uniform(
            bpm: 120,
            firstDownbeat: 0,
            beatsPerBar: 4,
            duration: 8
        )
        let value = chords(
            [
                ChordSegment(start: 0, end: 2, chord: chord(0)),
                ChordSegment(start: 2, end: 4, chord: chord(5)),
            ],
            duration: 8
        )

        let bars = value.bars(using: grid, duration: 8)

        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars[0].number, 1)
        XCTAssertEqual(bars[0].entries.count, 1)
        XCTAssertEqual(bars[0].entries.first?.chord, chord(0))
        XCTAssertEqual(bars[1].entries.first?.chord, chord(5))
    }

    func testTwoChordsInOneBarKeepTheirBeatPositions() {
        let grid = BeatGrid.uniform(bpm: 120, firstDownbeat: 0, beatsPerBar: 4, duration: 4)
        let value = chords(
            [
                ChordSegment(start: 0, end: 1, chord: chord(0)),
                ChordSegment(start: 1, end: 2, chord: chord(5)),
            ],
            duration: 4
        )

        let entries = value.bars(using: grid, duration: 4).first?.entries ?? []

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].beatOffset, 0)
        XCTAssertEqual(entries[1].beatOffset, 2)
    }

    func testAnUnreliableGridDrawsNoBarsAtAll() {
        // Bars drawn on guessed bar lines would be a picture of a song nobody
        // played. The ribbon covers this case instead.
        var grid = BeatGrid.uniform(bpm: 120, firstDownbeat: 0, beatsPerBar: 4, duration: 8)
        grid.isUserEdited = false
        grid.confidence = 0.1
        let value = chords([ChordSegment(start: 0, end: 2, chord: chord(0))], duration: 8)

        XCTAssertTrue(value.bars(using: grid, duration: 8).isEmpty)
    }

    // MARK: - Correction

    func testCorrectingAChordMarksItAsTheUsersAndCertain() {
        var value = chords([ChordSegment(start: 0, end: 2, chord: chord(0), confidence: 0.3)])
        let id = value.segments[0].id

        value.correct(id, to: chord(5, .minor))

        XCTAssertEqual(value.segments[0].chord, chord(5, .minor))
        XCTAssertEqual(value.segments[0].confidence, 1)
        XCTAssertTrue(value.segments[0].isUserEdited)
    }

    func testWritingASegmentOverAnotherSplitsItRatherThanDeletingIt() {
        var value = chords([ChordSegment(start: 0, end: 8, chord: chord(0))], duration: 8)

        value.apply(
            ChordSegment(start: 2, end: 4, chord: chord(7), confidence: 1, isUserEdited: true)
        )
        value.sanitize(duration: 8)

        XCTAssertEqual(value.segments.count, 3)
        XCTAssertEqual(value.segments.map(\.chord), [chord(0), chord(7), chord(0)])
        XCTAssertEqual(value.segments[1].start, 2)
        XCTAssertEqual(value.segments[2].end, 8)
    }

    func testReanalysisTakesTheFreshChartExceptWhereTheUserCorrectedIt() {
        // Unlike the beat grid this is not all-or-nothing: someone who fixed the
        // bridge should still get a better verse out of a rerun.
        var existing = chords(
            [
                ChordSegment(start: 0, end: 4, chord: chord(0)),
                ChordSegment(start: 4, end: 8, chord: chord(2)),
            ],
            duration: 8
        )
        existing.correct(existing.segments[1].id, to: chord(7))
        let fresh = chords(
            [
                ChordSegment(start: 0, end: 4, chord: chord(5)),
                ChordSegment(start: 4, end: 8, chord: chord(9, .minor)),
            ],
            duration: 8
        )

        let resolved = existing.resolvingReanalysis(fresh, duration: 8)

        XCTAssertEqual(resolved.segments.map(\.chord), [chord(5), chord(7)])
        XCTAssertTrue(resolved.segments[1].isUserEdited)
    }

    func testAChartWithNoCorrectionsIsSimplyReplaced() {
        let existing = chords([ChordSegment(start: 0, end: 4, chord: chord(0))], duration: 8)
        let fresh = chords([ChordSegment(start: 0, end: 4, chord: chord(5))], duration: 8)

        XCTAssertEqual(
            existing.resolvingReanalysis(fresh, duration: 8).segments.map(\.chord),
            [chord(5)]
        )
    }

    // MARK: - Honesty

    func testASongTheTemplatesCouldNotFitSaysSo() {
        let struggled = chords(
            [
                ChordSegment(start: 0, end: 4, chord: nil),
                ChordSegment(start: 4, end: 6, chord: chord(0), confidence: 0.2),
                ChordSegment(start: 6, end: 10, chord: chord(5), confidence: 0.9),
            ],
            duration: 10
        )

        XCTAssertEqual(struggled.unmodelledFraction, 0.6, accuracy: 0.0001)
        XCTAssertTrue(struggled.templatesStruggled)
    }

    func testAConfidentChartDoesNotApologise() {
        let clean = chords(
            [
                ChordSegment(start: 0, end: 5, chord: chord(0), confidence: 0.9),
                ChordSegment(start: 5, end: 10, chord: chord(5), confidence: 0.8),
            ],
            duration: 10
        )

        XCTAssertFalse(clean.templatesStruggled)
    }

    func testACorrectedChartIsTrustedWhateverTheDetectorThought() {
        var value = chords([ChordSegment(start: 0, end: 4, chord: chord(0))], duration: 8)
        value.confidence = 0.1

        XCTAssertFalse(value.isReliable)
        value.correct(value.segments[0].id, to: chord(5))
        XCTAssertTrue(value.isReliable)
    }

    func testTheVocabularyIsTheChordsTheSongUsesMostFirst() {
        let value = chords(
            [
                ChordSegment(start: 0, end: 2, chord: chord(0)),
                ChordSegment(start: 2, end: 8, chord: chord(5)),
                ChordSegment(start: 8, end: 10, chord: nil),
            ],
            duration: 10
        )

        XCTAssertEqual(value.vocabulary, [chord(5), chord(0)])
    }
}

// MARK: - Detector

final class ChordDetectorTests: XCTestCase {
    private let sampleRate = ChordDetector.sampleRate

    /// A chord played as sustained notes with a few harmonics each — which is
    /// what makes the overtone suppression worth testing rather than assuming.
    private func tone(
        pitchClasses: [Int],
        octave: Int = 4,
        seconds: Double,
        harmonics: Int = 4
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        for pitchClass in pitchClasses {
            let midi = Double(12 * octave + pitchClass)
            let frequency = 440 * pow(2, (midi - 69) / 12)
            for harmonic in 1...harmonics {
                let amplitude = Float(0.5 / Double(harmonic * harmonic))
                let partial = frequency * Double(harmonic)
                guard partial < sampleRate / 2 else { break }
                for index in samples.indices {
                    let time = Double(index) / sampleRate
                    samples[index] += amplitude * Float(sin(2 * .pi * partial * time))
                }
            }
        }
        return samples
    }

    private func meanChroma(_ samples: [Float], band: ClosedRange<Double>? = nil) -> [Float] {
        let chroma = ChordDetector.chromagram(
            samples: samples,
            sampleRate: sampleRate,
            band: band ?? ChordDetector.harmonicBand
        )
        let mean = chroma.mean(from: 0.2, to: Double(samples.count) / sampleRate - 0.2)
        return mean.chroma
    }

    func testTheChromaOfATriadIsThatTriadsThreeNotes() {
        let chroma = meanChroma(tone(pitchClasses: [0, 4, 7], seconds: 3))

        let strongest = chroma.enumerated()
            .sorted { $0.element > $1.element }
            .prefix(3)
            .map(\.offset)
            .sorted()

        XCTAssertEqual(strongest, [0, 4, 7])
    }

    func testOvertonesDoNotTurnALoneNoteIntoAChord() {
        // A single C with four harmonics has energy at C, G, and E. Without
        // overtone suppression its chroma reads as a C major triad; with it, C
        // stands clear of everything else.
        let chroma = meanChroma(tone(pitchClasses: [0], octave: 3, seconds: 3))

        let sorted = chroma.enumerated().sorted { $0.element > $1.element }

        XCTAssertEqual(sorted[0].offset, 0)
        XCTAssertGreaterThan(sorted[0].element, sorted[1].element * 1.5)
    }

    func testTheTemplatesPickTheChordThatIsPlaying() {
        let chroma = meanChroma(tone(pitchClasses: [0, 4, 7], seconds: 3))
        let silentBass = [Float](repeating: 0, count: 12)

        let scores = ChordDetector.scores(chroma: chroma, bass: silentBass, energy: 1)
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0

        XCTAssertEqual(ChordDetector.ChordState.all[best].chord, Chord(root: 0, quality: .major))
    }

    func testTheBassBreaksTheTieBetweenAChordAndItsRelativeMinor() {
        // C-E-G-A is C6 and Am7 written the same way. What tells them apart is
        // the note underneath, which is the whole reason for the bass term.
        var ambiguous = [Float](repeating: 0, count: 12)
        for pitch in [0, 4, 7, 9] { ambiguous[pitch] = 1 }

        func winner(bassPitch: Int) -> Chord? {
            var bass = [Float](repeating: 0, count: 12)
            bass[bassPitch] = 1
            let scores = ChordDetector.scores(chroma: ambiguous, bass: bass, energy: 1)
            let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0
            return ChordDetector.ChordState.all[best].chord
        }

        XCTAssertEqual(winner(bassPitch: 0)?.root, 0)
        XCTAssertEqual(winner(bassPitch: 9)?.root, 9)
    }

    func testSilenceIsNoChordRatherThanAGuess() {
        let scores = ChordDetector.scores(
            chroma: [Float](repeating: 0, count: 12),
            bass: [Float](repeating: 0, count: 12),
            energy: 0
        )
        let best = scores.indices.max { scores[$0] < scores[$1] } ?? 0

        XCTAssertNil(ChordDetector.ChordState.all[best].chord)
    }

    func testABassPlayingThroughABarStatesNoSingleNote() {
        var walking = [Float](repeating: 0, count: 12)
        walking[0] = 1
        walking[7] = 0.9

        XCTAssertNil(ChordDetector.bassPitchClass(walking))

        var settled = [Float](repeating: 0, count: 12)
        settled[5] = 1
        settled[0] = 0.2
        XCTAssertEqual(ChordDetector.bassPitchClass(settled), 5)
    }

    // MARK: - Decoding

    /// Emission scores for a run of beats, where `preferred` wins by `margin`.
    private func beatScores(
        preferred: [Int],
        margin: Double = 0.05
    ) -> [[Double]] {
        preferred.map { state in
            var scores = [Double](repeating: 0.5, count: ChordDetector.ChordState.all.count)
            scores[state] = 0.5 + margin
            return scores
        }
    }

    func testTheDecoderHoldsAChordThroughOneWobblyBeat() {
        // Harmony is piecewise constant. A single beat where a rival scores a
        // little higher — a passing note, a fill — must not become a chord.
        let cMajor = ChordDetector.ChordState.all.firstIndex(
            of: ChordDetector.ChordState(chord: Chord(root: 0, quality: .major))
        )!
        let rival = ChordDetector.ChordState.all.firstIndex(
            of: ChordDetector.ChordState(chord: Chord(root: 5, quality: .major))
        )!
        var preferred = [Int](repeating: cMajor, count: 8)
        preferred[4] = rival

        let path = ChordDetector.decode(beatScores: beatScores(preferred: preferred), key: nil)

        XCTAssertEqual(path, [Int](repeating: cMajor, count: 8))
    }

    func testARealChangeSurvivesTheSelfTransitionPrior() {
        let cMajor = ChordDetector.ChordState.all.firstIndex(
            of: ChordDetector.ChordState(chord: Chord(root: 0, quality: .major))
        )!
        let fMajor = ChordDetector.ChordState.all.firstIndex(
            of: ChordDetector.ChordState(chord: Chord(root: 5, quality: .major))
        )!
        let preferred = [Int](repeating: cMajor, count: 6) + [Int](repeating: fMajor, count: 6)

        let path = ChordDetector.decode(
            beatScores: beatScores(preferred: preferred, margin: 0.3),
            key: nil
        )

        XCTAssertEqual(path, preferred)
    }

    func testConfidenceIsHighWhenNothingElseComesClose() {
        var scores = [Double](repeating: 0.2, count: ChordDetector.ChordState.all.count)
        scores[3] = 0.9

        XCTAssertGreaterThan(ChordDetector.confidence(of: 3, in: scores), 0.9)
        XCTAssertLessThan(ChordDetector.confidence(of: 4, in: scores), 0.1)
    }

    // MARK: - Key

    func testTheKeyIsFoundFromWhatWasPlayed() {
        // A C major scale's worth of chroma, weighted the way tonal music is.
        let profile = ChordDetector.majorKeyProfile.map { Float($0) }

        XCTAssertEqual(
            ChordDetector.estimateKey(from: profile)?.key,
            MusicalKey(tonic: 0, isMinor: false)
        )
    }

    func testTheKeyIsCrossCheckedAgainstTheChordsThatWereDecoded() {
        let segments = [
            ChordSegment(start: 0, end: 4, chord: Chord(root: 7, quality: .major)),
            ChordSegment(start: 4, end: 8, chord: Chord(root: 0, quality: .major)),
            ChordSegment(start: 8, end: 12, chord: Chord(root: 2, quality: .major)),
            ChordSegment(start: 12, end: 16, chord: Chord(root: 7, quality: .major)),
        ]

        XCTAssertEqual(
            ChordDetector.keyFromChords(segments)?.key,
            MusicalKey(tonic: 7, isMinor: false)
        )
    }

    // MARK: - Bars and downbeats

    func testAOneBeatFragmentStraddlingABarLineIsPulledOntoIt() {
        let grid = BeatGrid.uniform(bpm: 120, firstDownbeat: 0, beatsPerBar: 4, duration: 8)
        // A change one beat before the bar line, lasting one beat: the decoder
        // hedging, not an anticipation worth keeping.
        let segments = [
            ChordSegment(start: 0, end: 1.5, chord: Chord(root: 0, quality: .major)),
            ChordSegment(start: 1.5, end: 2, chord: Chord(root: 5, quality: .major)),
            ChordSegment(start: 2, end: 4, chord: Chord(root: 7, quality: .major)),
        ]

        let aligned = ChordDetector.alignedToBars(segments, grid: grid)

        XCTAssertEqual(aligned[0].end, 2)
        XCTAssertEqual(aligned.count, 2)
    }

    func testALongChordIsNotDraggedOntoTheNearestBar() {
        let grid = BeatGrid.uniform(bpm: 120, firstDownbeat: 0, beatsPerBar: 4, duration: 16)
        // A genuine anticipation: the chord changes a beat early and stays for
        // four bars. That is a feature of the song, not a hedge.
        let segments = [
            ChordSegment(start: 0, end: 1.5, chord: Chord(root: 0, quality: .major)),
            ChordSegment(start: 1.5, end: 12, chord: Chord(root: 5, quality: .major)),
        ]

        XCTAssertEqual(ChordDetector.alignedToBars(segments, grid: grid)[0].end, 1.5)
    }

    func testChordChangesSayWhereTheBarStarts() {
        // Changes on beats 0, 4, 8, 12 — the phase the bar starts on.
        let changes = [4, 8, 12, 16, 20, 24]

        let phase = ChordDetector.downbeatPhase(changeBeatIndices: changes, beatsPerBar: 4)

        XCTAssertEqual(phase?.phase, 0)
        XCTAssertGreaterThan(phase?.confidence ?? 0, 0.5)
    }

    func testChangesScatteredEverywhereClaimNoPhase() {
        let changes = [1, 2, 3, 4, 5, 6, 7, 8]

        XCTAssertLessThan(
            ChordDetector.downbeatPhase(changeBeatIndices: changes, beatsPerBar: 4)?.confidence ?? 1,
            0.3
        )
    }

    // MARK: - Whole pipeline

    func testAProgressionIsDecodedFromAudio() {
        let progression: [Chord] = [
            Chord(root: 0, quality: .major),
            Chord(root: 9, quality: .minor),
            Chord(root: 5, quality: .major),
            Chord(root: 7, quality: .major),
        ]
        var samples: [Float] = []
        for chord in progression {
            samples += tone(pitchClasses: chord.pitchClasses, seconds: 2)
        }
        let beatTimes = stride(from: 0.0, through: 8.0, by: 0.5).map { $0 }

        let chroma = ChordDetector.chromagram(samples: samples, sampleRate: sampleRate)
        let beats = ChordDetector.beatAveraged(chroma, beatTimes: beatTimes)
        let silent = [Float](repeating: 0, count: 12)
        let scores = beats.chroma.indices.map { index in
            ChordDetector.scores(
                chroma: beats.chroma[index],
                bass: silent,
                energy: beats.energies[index]
            )
        }
        let path = ChordDetector.decode(beatScores: scores, key: nil)
        let decoded = ChordDetector.assemble(
            path: path,
            beatScores: scores,
            beatTimes: beatTimes,
            beatBass: [],
            duration: 8
        )

        XCTAssertEqual(decoded.segments.compactMap(\.chord), progression)
    }
}
