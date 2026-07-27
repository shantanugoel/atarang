import XCTest
@testable import Atarang

final class ChordShapeTests: XCTestCase {
    func testTheOpenShapesAreOpenPosition() {
        for (chord, shape) in ChordShapes.open {
            XCTAssertTrue(
                shape.isOpen,
                "\(chord.symbol(preferringFlats: false)) is in the open table but is not an open shape"
            )
        }
    }

    func testEveryOpenShapeSoundsTheChordItClaims() {
        // Standard tuning, low to high, as pitch classes.
        let strings = [4, 9, 2, 7, 11, 4]
        for (chord, shape) in ChordShapes.open {
            let sounded = Set(
                zip(strings, shape.frets).compactMap { open, fret in
                    fret.map { PitchClass.normalized(open + $0) }
                }
            )
            let wanted = Set(chord.pitchClasses)
            // Every note has to belong to the chord, and the root and the note
            // that decides the quality have to be there. The fifth is allowed
            // to be missing — the standard C7 grip drops it, as most seventh
            // shapes on six strings do.
            XCTAssertTrue(
                sounded.isSubset(of: wanted),
                "\(shape.name) sounds \(sounded.sorted()), which is not all in \(wanted.sorted())"
            )
            XCTAssertTrue(sounded.contains(chord.root), "\(shape.name) has no root")
            let quality = PitchClass.normalized(chord.root + chord.quality.intervals[1])
            XCTAssertTrue(
                sounded.contains(quality),
                "\(shape.name) is missing the note that makes it a \(chord.quality.spokenName)"
            )
        }
    }

    func testABarreShapeIsTheOpenShapeMovedUp() {
        // F major is E major at the first fret, which is why it is the chord
        // every beginner meets and dreads.
        let shapes = ChordShapes.shapes(for: Chord(root: 5, quality: .major))

        XCTAssertFalse(shapes.isEmpty)
        XCTAssertTrue(shapes[0].isBarre)
        XCTAssertEqual(shapes[0].barreFret, 1)
        XCTAssertEqual(shapes[0].frets, [1, 3, 3, 2, 1, 1])
    }

    func testAnOpenShapeIsPreferredToABarre() {
        let shapes = ChordShapes.shapes(for: Chord(root: 7, quality: .major))

        XCTAssertTrue(shapes[0].isOpen)
        XCTAssertEqual(shapes[0].name, "G")
    }

    func testEaseRanksTheFirstShapesAboveBarres() {
        XCTAssertEqual(ChordShapes.ease(of: Chord(root: 7, quality: .major)), 1)
        XCTAssertGreaterThan(
            ChordShapes.ease(of: Chord(root: 7, quality: .major)),
            ChordShapes.ease(of: Chord(root: 6, quality: .major))
        )
    }

    func testAShapeThisCatalogueDoesNotHaveIsAdmittedRatherThanInvented() {
        // No open diminished shape and no sixth-string form for it: the answer
        // is the fifth-string barre, and never a made-up box.
        let shapes = ChordShapes.shapes(for: Chord(root: 0, quality: .diminished))

        XCTAssertTrue(shapes.allSatisfy { $0.isBarre })
    }
}

final class ChordSimplificationTests: XCTestCase {
    private func chart(_ chords: [Chord?], barLength: TimeInterval = 2) -> SongChords {
        var value = SongChords(
            segments: chords.enumerated().map { index, chord in
                ChordSegment(
                    start: Double(index) * barLength,
                    end: Double(index + 1) * barLength,
                    chord: chord,
                    confidence: 0.9
                )
            },
            key: MusicalKey(tonic: 0, isMinor: false),
            confidence: 0.9
        )
        value.sanitize(duration: Double(chords.count) * barLength)
        return value
    }

    private func symbols(_ chords: SongChords) -> [String] {
        chords.segments.map { $0.symbol(preferringFlats: false) }
    }

    func testFullChangesNothing() {
        let source = chart([
            Chord(root: 0, quality: .majorSeventh),
            Chord(root: 7, quality: .dominantSeventh)
        ])

        let result = ChordPlayability.apply(.none, to: source, duration: 4)

        XCTAssertEqual(symbols(result.chords), ["Cmaj7", "G7"])
        XCTAssertTrue(result.chords.segments.allSatisfy { !$0.isSimplified })
    }

    func testSimpleReducesSeventhsToTheirTriads() {
        let source = chart([
            Chord(root: 0, quality: .majorSeventh),
            Chord(root: 9, quality: .minorSeventh),
            Chord(root: 2, quality: .suspendedFourth)
        ])
        var options = ChordDisplayOptions.none
        options.complexity = .simple

        let result = ChordPlayability.apply(options, to: source, duration: 6)

        // sus4 is already a triad and stays: reducing it would print a chord
        // that is audibly not the one being played.
        XCTAssertEqual(symbols(result.chords), ["C", "Am", "Dsus4"])
        XCTAssertEqual(result.chords.segments[0].detected?.quality, .majorSeventh)
        XCTAssertTrue(result.chords.segments[0].isSimplified)
    }

    func testBeginnerProducesOpenShapesOrSaysItCannot() {
        let source = chart([
            Chord(root: 0, quality: .majorSeventh),   // Cmaj7 is open already
            Chord(root: 11, quality: .diminished),    // Bdim has no open shape
            Chord(root: 9, quality: .minorSeventh)    // Am7 is open already
        ])
        var options = ChordDisplayOptions.none
        options.complexity = .beginner

        let result = ChordPlayability.apply(options, to: source, duration: 6)

        // B diminished has no open shape, and neither does the B minor it
        // would reduce to. It stays as it was heard and is reported, because
        // printing a chord the song does not contain would be worse than
        // printing one that is hard.
        XCTAssertEqual(symbols(result.chords), ["Cmaj7", "Bdim", "Am7"])
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.unplayable.first?.root, 11)
    }

    func testBeginnerIsCompleteWhenEveryChordHasAnOpenShape() {
        let source = chart([
            Chord(root: 0, quality: .major),
            Chord(root: 9, quality: .minor),
            Chord(root: 5, quality: .majorSeventh),
            Chord(root: 7, quality: .dominantSeventh)
        ])
        var options = ChordDisplayOptions.none
        options.complexity = .beginner

        let result = ChordPlayability.apply(options, to: source, duration: 8)

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(
            result.chords.segments.allSatisfy { segment in
                segment.chord.map(ChordShapes.isOpen) ?? false
            }
        )
    }

    func testPowerKeepsTheRootAndDropsTheThird() {
        let source = chart([
            Chord(root: 4, quality: .minor),
            Chord(root: 9, quality: .dominantSeventh)
        ])
        var options = ChordDisplayOptions.none
        options.complexity = .power

        let result = ChordPlayability.apply(options, to: source, duration: 4)

        XCTAssertEqual(symbols(result.chords), ["E5", "A5"])
        XCTAssertEqual(result.chords.segments[0].detected?.quality, .minor)
    }

    func testHidingInversionsLeavesTheGrip() {
        let source = chart([Chord(root: 0, quality: .major, bass: 4)])
        var options = ChordDisplayOptions.none
        options.hidesInversions = true

        let result = ChordPlayability.apply(options, to: source, duration: 2)

        XCTAssertEqual(symbols(result.chords), ["C"])
        XCTAssertEqual(result.chords.segments[0].detected?.bass, 4)
    }

    func testPassingChordsAreAbsorbedIntoTheChordBeforeThem() {
        var value = SongChords(segments: [
            ChordSegment(start: 0, end: 2, chord: Chord(root: 0, quality: .major)),
            ChordSegment(start: 2, end: 2.2, chord: Chord(root: 4, quality: .minor)),
            ChordSegment(start: 2.2, end: 4, chord: Chord(root: 5, quality: .major))
        ])
        value.sanitize(duration: 4)
        var options = ChordDisplayOptions.none
        options.hidesPassingChords = true

        let result = ChordPlayability.apply(options, to: value, duration: 4, beatDuration: 0.5)

        XCTAssertEqual(symbols(result.chords), ["C", "F"])
        XCTAssertEqual(result.chords.segments[0].end, 2.2, accuracy: 0.001)
    }

    func testACorrectionIsNeverTreatedAsAPassingChord() {
        var value = SongChords(segments: [
            ChordSegment(start: 0, end: 2, chord: Chord(root: 0, quality: .major)),
            ChordSegment(
                start: 2,
                end: 2.2,
                chord: Chord(root: 4, quality: .minor),
                confidence: 1,
                isUserEdited: true
            )
        ])
        value.sanitize(duration: 2.2)
        var options = ChordDisplayOptions.none
        options.hidesPassingChords = true

        let result = ChordPlayability.apply(options, to: value, duration: 2.2, beatDuration: 0.5)

        XCTAssertEqual(symbols(result.chords), ["C", "Em"])
    }

    func testACapoPrintsTheShapeRatherThanTheSoundingChord() {
        // E♭ major with a capo at the third fret is a C shape.
        let source = chart([Chord(root: 3, quality: .major)])
        var options = ChordDisplayOptions.none
        options.capo = 3

        let result = ChordPlayability.apply(options, to: source, duration: 2)

        XCTAssertEqual(result.chords.segments[0].chord?.root, 0)
    }

    func testSimplificationIsNeverWrittenToDisk() throws {
        // The lens must not become a fact about the song: `detected` is outside
        // `CodingKeys` precisely so a simplified chart cannot be persisted as
        // though it were the analysis.
        let segment = ChordSegment(
            start: 0,
            end: 2,
            chord: Chord(root: 0, quality: .major),
            detected: Chord(root: 0, quality: .majorSeventh)
        )

        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(ChordSegment.self, from: data)

        XCTAssertNil(decoded.detected)
        XCTAssertEqual(decoded.chord, Chord(root: 0, quality: .major))
        XCTAssertFalse(
            String(data: data, encoding: .utf8)?.contains("detected") ?? true
        )
    }

    func testThePowerChordIsNeverSomethingTheDetectorCanClaim() {
        XCTAssertFalse(ChordQuality.detectable.contains(.power))
        XCTAssertFalse(
            ChordDetector.ChordState.all.contains { $0.chord?.quality == .power }
        )
    }
}

final class CapoSuggestionTests: XCTestCase {
    private func chart(_ chords: [Chord]) -> SongChords {
        var value = SongChords(
            segments: chords.enumerated().map { index, chord in
                ChordSegment(
                    start: Double(index) * 4,
                    end: Double(index + 1) * 4,
                    chord: chord,
                    confidence: 0.9
                )
            }
        )
        value.sanitize(duration: Double(chords.count) * 4)
        return value
    }

    func testASongAlreadyInOpenShapesIsToldToLeaveTheCapoOff() {
        let source = chart([
            Chord(root: 7, quality: .major),
            Chord(root: 2, quality: .major),
            Chord(root: 4, quality: .minor),
            Chord(root: 0, quality: .major)
        ])

        XCTAssertEqual(ChordPlayability.bestCapo(for: source)?.fret, 0)
    }

    func testAFlatKeySongIsGivenACapoThatMakesItOpen() {
        // B♭ – E♭ – F – Gm is three barre chords; capo 3 turns them into
        // G – C – D – Em, which is the first thing anybody learns.
        let source = chart([
            Chord(root: 10, quality: .major),
            Chord(root: 3, quality: .major),
            Chord(root: 5, quality: .major),
            Chord(root: 7, quality: .minor)
        ])

        let best = try? XCTUnwrap(ChordPlayability.bestCapo(for: source))

        XCTAssertEqual(best?.fret, 3)
        XCTAssertEqual(best?.openShare ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(
            best?.shapes.map { $0.symbol(preferringFlats: false) }.sorted(),
            ["C", "D", "Em", "G"]
        )
    }

    func testTheSuggestionIsWeightedByHowLongEachChordIsPlayed() {
        // Thirty seconds of G and two of B♭: this is a G song, and a capo that
        // fixes the B♭ at the cost of the G is the wrong answer.
        var value = SongChords(segments: [
            ChordSegment(start: 0, end: 30, chord: Chord(root: 7, quality: .major)),
            ChordSegment(start: 30, end: 32, chord: Chord(root: 10, quality: .major))
        ])
        value.sanitize(duration: 32)

        XCTAssertEqual(ChordPlayability.bestCapo(for: value)?.fret, 0)
    }

    func testAPlayableKeyShiftIsOfferedForASongInAHardKey()  {
        let source = chart([
            Chord(root: 1, quality: .major),
            Chord(root: 6, quality: .major),
            Chord(root: 8, quality: .major)
        ])

        let best = ChordPlayability.playableKeys(for: source).first

        XCTAssertNotNil(best)
        XCTAssertNotEqual(best?.semitones, 0)
        XCTAssertEqual(best?.openShare ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(abs(best?.semitones ?? 99) <= 6)
    }

    func testAnEasySongIsLeftAtItsOwnPitch() {
        // G – Em – C – D: four shapes from the first month of playing, so
        // there is nothing a shift could improve.
        let source = chart([
            Chord(root: 7, quality: .major),
            Chord(root: 4, quality: .minor),
            Chord(root: 0, quality: .major),
            Chord(root: 2, quality: .major)
        ])

        XCTAssertEqual(ChordPlayability.playableKeys(for: source).first?.semitones, 0)
    }
}

final class ChordSheetTests: XCTestCase {
    private func lyrics(_ lines: [LyricLine]) -> SongLyrics {
        var value = SongLyrics(source: .manual, lines: lines)
        value.sanitize(duration: 60)
        return value
    }

    private func chart(_ entries: [(TimeInterval, TimeInterval, Chord)]) -> SongChords {
        var value = SongChords(
            segments: entries.map {
                ChordSegment(start: $0.0, end: $0.1, chord: $0.2, confidence: 0.9)
            }
        )
        value.sanitize(duration: 60)
        return value
    }

    func testWordTimingsPlaceAChordOverTheWordBeingSung() {
        let words = lyrics([
            LyricLine(
                text: "the quick brown fox",
                start: 0,
                end: 4,
                words: [
                    LyricWord(text: "the", start: 0),
                    LyricWord(text: "quick", start: 1),
                    LyricWord(text: "brown", start: 2),
                    LyricWord(text: "fox", start: 3)
                ]
            )
        ])
        let chords = chart([
            (0, 2, Chord(root: 0, quality: .major)),
            (2, 4, Chord(root: 5, quality: .major))
        ])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 4)

        XCTAssertTrue(sheet.hasExactPlacements)
        XCTAssertFalse(sheet.hasEstimatedPlacements)
        XCTAssertEqual(sheet.lines[0].chords.map(\.symbol), ["C", "F"])
        // "brown" starts at character 10 of "the quick brown fox".
        XCTAssertEqual(sheet.lines[0].chords[1].characterIndex, 10)
        XCTAssertTrue(sheet.lines[0].chords.allSatisfy(\.isExact))
    }

    func testWithoutWordTimingsAChordIsInterpolatedAndSaidToBe() {
        let words = lyrics([LyricLine(text: "the quick brown fox", start: 0, end: 4)])
        let chords = chart([
            (0, 2, Chord(root: 0, quality: .major)),
            (2, 4, Chord(root: 5, quality: .major))
        ])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 4)

        XCTAssertFalse(sheet.hasExactPlacements)
        XCTAssertTrue(sheet.hasEstimatedPlacements)
        XCTAssertEqual(sheet.lines[0].chords.count, 2)
        XCTAssertFalse(sheet.lines[0].chords[1].isExact)
        // Halfway through the line, pulled back to the start of the word it
        // lands in rather than printed over the middle of one.
        let index = sheet.lines[0].chords[1].characterIndex
        let characters = Array("the quick brown fox")
        XCTAssertTrue(index == 0 || characters[index - 1] == " ")
    }

    func testTheChunksReassembleIntoTheLine() {
        let words = lyrics([
            LyricLine(
                text: "the quick brown fox",
                start: 0,
                end: 4,
                words: [
                    LyricWord(text: "the", start: 0),
                    LyricWord(text: "quick", start: 1),
                    LyricWord(text: "brown", start: 2),
                    LyricWord(text: "fox", start: 3)
                ]
            )
        ])
        let chords = chart([
            (0, 1, Chord(root: 0, quality: .major)),
            (1, 3, Chord(root: 5, quality: .major)),
            (3, 4, Chord(root: 7, quality: .major))
        ])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 4)

        XCTAssertEqual(
            sheet.lines[0].chunks.map(\.text).joined(),
            "the quick brown fox"
        )
    }

    func testAnInstrumentalIntroIsPrintedAboveTheFirstLine() {
        let words = lyrics([LyricLine(text: "here we go", start: 8, end: 10)])
        let chords = chart([
            (0, 4, Chord(root: 0, quality: .major)),
            (4, 8, Chord(root: 5, quality: .major)),
            (8, 10, Chord(root: 7, quality: .major))
        ])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 10)

        XCTAssertEqual(sheet.lines[0].leadingChords.map(\.symbol), ["C", "F"])
        XCTAssertEqual(sheet.lines[0].chords.map(\.symbol), ["G"])
    }

    func testUntimedLyricsSayWhatIsMissingRatherThanGuessing() {
        let words = lyrics([LyricLine(text: "no times here")])
        let chords = chart([(0, 4, Chord(root: 0, quality: .major))])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 4)

        XCTAssertTrue(sheet.needsTiming)
        XCTAssertTrue(sheet.lines[0].chords.isEmpty)
    }

    func testEveryChordIsPlacedExactlyOnce() {
        let words = lyrics([
            LyricLine(text: "first line", start: 0, end: 4),
            LyricLine(text: "second line", start: 4, end: 8)
        ])
        let chords = chart([
            (0, 2, Chord(root: 0, quality: .major)),
            (2, 4, Chord(root: 5, quality: .major)),
            (4, 6, Chord(root: 7, quality: .major)),
            (6, 8, Chord(root: 9, quality: .minor))
        ])

        let sheet = ChordSheet.build(lyrics: words, chords: chords, duration: 8)

        let placed = sheet.lines.flatMap { $0.chords + $0.leadingChords }
        XCTAssertEqual(placed.count, 4)
        XCTAssertEqual(Set(placed.map(\.id)).count, 4)
    }
}
