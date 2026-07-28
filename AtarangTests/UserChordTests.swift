import XCTest
@testable import Atarang

final class ChordSymbolParserTests: XCTestCase {
    func testRichSymbolsRoundTripAndTransposeWithoutSuffixLoss() throws {
        let symbols = [
            "C", "Cm", "C5", "Csus2", "Csus4", "C6", "Cm6", "C7",
            "Cmaj7", "Cm7", "Cdim", "Cdim7", "Caug", "Cm7b5",
            "Cadd2", "Cadd4", "Cadd9", "C9", "Cmaj9", "Cm9", "C(b5)", "C(#5)",
        ]

        for symbol in symbols {
            guard case .chord(let chord) = ChordSymbolParser.parse(symbol) else {
                return XCTFail("Did not parse \(symbol)")
            }
            let data = try JSONEncoder().encode(chord)
            let decoded = try JSONDecoder().decode(Chord.self, from: data)
            XCTAssertEqual(decoded, chord)
            XCTAssertEqual(decoded.transposed(by: 2).quality, chord.quality)
        }
    }

    func testUnicodeAccidentalsAndSlashBassAreNormalized() {
        guard case .chord(let chord) = ChordSymbolParser.parse("D♭maj9/A♭") else {
            return XCTFail("Did not parse Unicode chord")
        }

        XCTAssertEqual(chord.root, 1)
        XCTAssertEqual(chord.bass, 8)
        XCTAssertEqual(chord.quality, .majorNinth)
        XCTAssertEqual(chord.symbol(preferringFlats: true), "D♭maj9/A♭")
    }

    func testCapoShapesBecomeSoundingChords() {
        guard case .chord(let chord) = ChordSymbolParser.parse("G/B", sourceCapo: 2) else {
            return XCTFail("Did not parse capo chord")
        }

        XCTAssertEqual(chord.root, 9)
        XCTAssertEqual(chord.bass, 1)
        XCTAssertEqual(chord.symbol(preferringFlats: false), "A/C♯")
    }

    func testUnknownFormulaDoesNotSilentlyBecomeAnotherChord() {
        XCTAssertNil(ChordSymbolParser.parse("CtotallyUnknown"))
    }

    func testNoChordIsDistinctFromAParseFailure() {
        XCTAssertEqual(ChordSymbolParser.parse("N.C."), .noChord)
        XCTAssertNil(ChordSymbolParser.parse("not a chord"))
    }

    /// A lowercase Roman numeral is minor whether or not it carries an
    /// extension. Reading only the suffix turned `vi7` into a dominant chord.
    func testLowercaseRomanNumeralsKeepTheirMinorThird() {
        let key = MusicalKey(tonic: 0, isMinor: false)

        for (symbol, expected) in [
            ("vi", ChordQuality.minor),
            ("vi7", .minorSeventh),
            ("ii9", .minorNinth),
            ("VI", .major),
            ("V7", .dominantSeventh),
            ("visus4", .suspendedFourth),
        ] {
            guard case .chord(let chord) = ChordSymbolParser.parse(symbol, key: key) else {
                return XCTFail("Did not parse \(symbol)")
            }
            XCTAssertEqual(chord.quality, expected, "for \(symbol)")
        }
    }

    /// Charts write the accidental before the degree, never after it.
    func testFlattenedDegreesParse() {
        let key = MusicalKey(tonic: 0, isMinor: false)

        guard case .chord(let seventh) = ChordSymbolParser.parse("b7", key: key),
              case .chord(let third) = ChordSymbolParser.parse("b3", key: key) else {
            return XCTFail("Did not parse a flattened degree")
        }

        XCTAssertEqual(seventh.root, 10)
        XCTAssertEqual(third.root, 3)
    }

    /// Degrees are only safe where the author marked the text as a chord.
    func testDegreesAreRefusedWhenNotAllowed() {
        let key = MusicalKey(tonic: 0, isMinor: false)

        XCTAssertNil(ChordSymbolParser.parse("I", key: key, allowsDegrees: false))
        XCTAssertNotNil(ChordSymbolParser.parse("I", key: key))
    }
}

final class UserChordParserTests: XCTestCase {
    func testChordProParsesMetadataSectionsLyricsAndWarnings() {
        let document = UserChordParser.parse(
            """
            {title: Synthetic Song}
            {artist: Test Fixture}
            {key: C}
            {capo: 2}
            {time: 4/4}
            {start_of_verse: Verse 1}
            [G]alpha [D/F#]beta
            {unsupported_directive: retained}
            """
        )

        XCTAssertEqual(document.metadata.title, "Synthetic Song")
        XCTAssertEqual(document.metadata.sourceCapo, 2)
        XCTAssertEqual(document.metadata.beatsPerBar, 4)
        XCTAssertEqual(document.sections.first?.name, "Verse 1")
        XCTAssertEqual(document.events.count, 2)
        XCTAssertEqual(document.events[0].chord?.root, 9)
        XCTAssertEqual(document.lyricAnchors.first?.text, "alpha beta")
        XCTAssertTrue(document.warnings.contains { $0.kind == .unknownDirective })
    }

    func testSmartPastePairsChordColumnsWithTheFollowingLyric() {
        let document = UserChordParser.parse(
            """
                G          D/F#
            alpha beta gamma
            """
        )

        XCTAssertEqual(document.events.count, 2)
        guard case .lyric(let firstLine, let firstColumn) = document.events[0].location,
              case .lyric(let secondLine, let secondColumn) = document.events[1].location else {
            return XCTFail("Expected lyric anchors")
        }
        XCTAssertEqual(firstLine, secondLine)
        XCTAssertLessThan(firstColumn, secondColumn)
    }

    func testGridPreservesBarsAndBeatCells() {
        let document = UserChordParser.parse("| C . G . | Am . F . |")

        XCTAssertEqual(document.events.count, 4)
        guard case .grid(let bar, let beat) = document.events[1].location else {
            return XCTFail("Expected a grid location")
        }
        XCTAssertEqual(bar, 0)
        XCTAssertEqual(beat, 2)
    }

    func testTabIsIgnoredRatherThanParsedAsChords() {
        let document = UserChordParser.parse(
            """
            e|---0---2---3---|
            B|---1---3---0---|
            C G Am F
            """
        )

        XCTAssertEqual(document.events.count, 4)
        XCTAssertEqual(document.warnings.filter { $0.kind == .ignoredTab }.count, 2)
    }

    /// A chart routinely holds one chord over a whole line. Requiring two
    /// chords before a line counted lost every one of them.
    func testASingleChordOverALineIsAChordLine() {
        let document = UserChordParser.parse(
            """
            [Verse]
            G
            words of the opening line
            """
        )

        XCTAssertEqual(document.events.count, 1)
        XCTAssertEqual(document.events.first?.printedSymbol, "G")
        XCTAssertEqual(document.lyricAnchors.map(\.text), ["words of the opening line"])
    }

    /// Every word of "Am I" spells a chord. It is still a line of a song.
    func testShortLyricLinesAreNotEatenAsChords() {
        let document = UserChordParser.parse(
            """
            {key: C}
            Am I
            the only one
            """
        )

        XCTAssertTrue(document.events.isEmpty)
        XCTAssertEqual(document.lyricAnchors.map(\.text), ["Am I", "the only one"])
    }

    /// Chart pages print the capo in prose above the chart, not as a
    /// directive.
    func testPlainTextCapoAndHeadersAreRead() {
        let document = UserChordParser.parse(
            """
            Artist: Test Fixture
            Capo: 2nd fret
            Tuning: E A D G B e

            G          Am
            first line of the words
            """
        )

        XCTAssertEqual(document.metadata.sourceCapo, 2)
        XCTAssertEqual(document.metadata.artist, "Test Fixture")
        // Printed G with a capo at the second fret sounds as A.
        XCTAssertEqual(document.events.first?.chord?.root, 9)
        XCTAssertEqual(document.events.first?.printedSymbol, "G")
    }

    /// The capo line is not always above the first chord.
    func testCapoAppliesToChordsWrittenBeforeItWasDeclared() {
        let document = UserChordParser.parse(
            """
            [Verse]
            C
            first line of the words

            {capo: 2}
            """
        )

        XCTAssertEqual(document.events.first?.chord?.root, 2)
    }

    /// The printed symbol is provenance and must stay printed, so an export
    /// plus a re-import does not stack the capo twice.
    func testExportedChartReimportsToTheSameSoundingChords() {
        let document = UserChordParser.parse(
            """
            {capo: 2}
            [G]alpha [Am]beta
            """
        )
        let chart = UserChordChart(
            name: "Round trip",
            origin: .pasted,
            sourceMetadata: document.metadata,
            document: document
        )

        let reimported = UserChordParser.parse(ChordProExporter.text(for: chart))

        XCTAssertEqual(
            reimported.events.compactMap(\.chord?.root),
            document.events.compactMap(\.chord?.root)
        )
    }
}

final class UserChordAlignmentTests: XCTestCase {
    private func lyrics(
        _ lines: [(String, TimeInterval, [(String, TimeInterval)])],
        sections: [Int: String] = [:]
    ) -> SongLyrics {
        var built: [LyricLine] = []
        for (index, line) in lines.enumerated() {
            if let label = sections[index] {
                built.append(LyricLine(text: label, sectionLabel: label))
            }
            built.append(
                LyricLine(
                    text: line.0,
                    start: line.1,
                    words: line.2.map { LyricWord(text: $0.0, start: $0.1) }
                )
            )
        }
        return SongLyrics(source: .manual, lines: built)
    }

    func testWordTimedLyricsPlaceChordsOnMatchedWords() throws {
        let document = UserChordParser.parse("[C]alpha [F]beta")
        let song = lyrics([("alpha beta", 4, [("alpha", 4), ("beta", 6)])])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 10)
        )

        XCTAssertEqual(result.chords.segments.map(\.start), [4, 6])
        XCTAssertFalse(result.alignment.usedEstimatedPlacements)
        XCTAssertGreaterThan(result.alignment.lyricAnchorCoverage, 0.9)
    }

    func testGridEventsMapToDetectedBeatsWithoutChangingLabels() throws {
        let document = UserChordParser.parse("| C . G . | Am . F . |")
        let grid = BeatGrid.uniform(
            bpm: 120,
            firstDownbeat: 0,
            beatsPerBar: 4,
            duration: 8
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: nil, grid: grid, duration: 8)
        )

        XCTAssertEqual(result.chords.segments.map(\.start), [0, 1, 2, 3])
        XCTAssertEqual(
            result.chords.segments.compactMap(\.chord).map(\.root),
            [0, 7, 9, 5]
        )
    }

    func testDurationMismatchIsSurfaced() throws {
        var document = UserChordParser.parse("C G Am F")
        document.metadata.duration = 100

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: nil, grid: nil, duration: 50)
        )

        XCTAssertTrue(result.alignment.likelyArrangementMismatch)
        XCTAssertTrue(result.alignment.warnings.contains { $0.kind == .arrangementMismatch })
    }

    func testAudioEvidenceMovesUnresolvedEventsWithoutChangingRichLabels() throws {
        let document = UserChordParser.parse("Cmaj9 Fm9")
        let beats = [
            Self.evidence([0, 2, 4, 7, 11], at: 0),
            Self.evidence([0, 2, 4, 7, 11], at: 1),
            Self.evidence([5, 8, 0, 3], at: 2),
            Self.evidence([5, 8, 0, 3], at: 3),
        ]

        let result = try XCTUnwrap(
            UserChordAligner.align(
                document,
                lyrics: nil,
                grid: nil,
                duration: 4,
                evidence: beats
            )
        )

        XCTAssertEqual(result.chords.segments.map { $0.chord?.quality }, [.majorNinth, .minorNinth])
        XCTAssertNotNil(result.alignment.audioAgreement)
        XCTAssertFalse(result.alignment.usedEstimatedPlacements)
    }

    /// Two chords on one syllable are two chords. One of them used to be
    /// dropped, silently, by the zero-length guard in `sanitize`.
    func testTwoChordsOnOneWordBothSurvive() throws {
        let document = UserChordParser.parse("[C]al[F]pha [G]beta")
        let song = lyrics([("alpha beta", 4, [("alpha", 4), ("beta", 6)])])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 10)
        )

        XCTAssertEqual(
            result.chords.segments.compactMap { $0.chord?.symbol(preferringFlats: false) },
            ["C", "F", "G"]
        )
    }

    /// The chord's column belongs to the chart's line, not the recording's.
    /// Reading it straight across put chords on whichever word happened to sit
    /// at that character offset in the other text.
    func testChordLandsOnTheRightWordWhenTheTwoTextsDiffer() throws {
        let document = UserChordParser.parse("[C]hello [G]world")
        let song = lyrics([
            ("hello beautiful world", 4, [("hello", 4), ("beautiful", 6), ("world", 9)])
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 20)
        )

        XCTAssertEqual(result.chords.segments.map(\.start), [4, 9])
    }

    /// A chart writes the chorus once; the recording sings it twice. Each
    /// occurrence has to find its own place in time rather than both landing on
    /// the first.
    func testRepeatedChorusLinesAlignToDistinctOccurrences() throws {
        let document = UserChordParser.parse(
            """
            [Verse 1]
            C     G
            first verse line

            [Chorus]
            F   Am
            the chorus line

            [Verse 2]
            C      G
            second verse line

            [Chorus]
            F   Am
            the chorus line
            """
        )
        let song = lyrics([
            ("first verse line", 10, [("first", 10), ("verse", 11), ("line", 12)]),
            ("the chorus line", 20, [("the", 20), ("chorus", 21), ("line", 22)]),
            ("second verse line", 30, [("second", 30), ("verse", 31), ("line", 32)]),
            ("the chorus line", 40, [("the", 40), ("chorus", 41), ("line", 42)]),
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 60)
        )

        // Each chorus is placed on its own occurrence, not both on the first.
        XCTAssertEqual(
            result.chords.segments.compactMap { $0.chord?.symbol(preferringFlats: false) },
            ["C", "G", "F", "Am", "C", "G", "F", "Am"]
        )
        XCTAssertEqual(
            result.chords.segments.map(\.start),
            [10, 11, 20, 21, 30, 31, 40, 41]
        )
        XCTAssertEqual(result.alignment.lyricAnchorCoverage, 1)
    }

    /// A line the recording never sings should land between the lines around
    /// it, not be flung across the whole song by an even spread.
    func testUnmatchedLinesInterpolateBetweenTheirNeighbours() throws {
        let document = UserChordParser.parse(
            """
            C
            first line of the song

            G
            a line this recording leaves out

            D
            last line of the song
            """
        )
        let song = lyrics([
            ("first line of the song", 10, [("first", 10)]),
            ("last line of the song", 50, [("last", 50)]),
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 200)
        )

        let starts = result.chords.segments.map(\.start)
        XCTAssertEqual(starts.first, 10)
        XCTAssertEqual(starts.last, 50)
        XCTAssertGreaterThan(starts[1], 10)
        XCTAssertLessThan(starts[1], 50)
        XCTAssertTrue(result.alignment.usedEstimatedPlacements)
    }

    /// The chart's order is the song's order. A single bad placement must not
    /// be allowed to reorder the chords around it.
    func testChartOrderIsPreservedWhenOnePlacementDisagrees() throws {
        let document = UserChordParser.parse(
            """
            C
            second line sung

            G
            first line sung
            """
        )
        // The recording sings these in the opposite order to the chart.
        let song = lyrics([
            ("first line sung", 5, [("first", 5)]),
            ("second line sung", 40, [("second", 40)]),
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 90)
        )

        XCTAssertEqual(
            result.chords.segments.compactMap { $0.chord?.symbol(preferringFlats: false) },
            ["C", "G"]
        )
        let starts = result.chords.segments.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    /// A chart for a different song matches almost nothing, and should say so
    /// rather than report a confident alignment.
    func testAChartForAnotherSongIsFlagged() throws {
        let chartLines = (1...10).map { "C\nline number \($0) of another song entirely\n" }
        let document = UserChordParser.parse(chartLines.joined(separator: "\n"))
        let song = lyrics(
            (1...10).map { ("nothing here resembles that chart \($0)", TimeInterval($0) * 5, []) }
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 60)
        )

        XCTAssertTrue(result.alignment.likelyArrangementMismatch)
        XCTAssertTrue(result.alignment.warnings.contains { $0.kind == .arrangementMismatch })
    }

    /// The whole shape of a pasted chart page, start to finish.
    func testPastedChartPageAlignsToWordTimings() throws {
        let document = UserChordParser.parse(
            """
            Artist: Test Fixture
            Capo: 2nd fret

            [Intro]
            Em

            [Verse 1]
            Em              D
            walking down the road
                    C            G
            singing every single note
            """
        )
        let song = lyrics([
            (
                "walking down the road", 12,
                [("walking", 12), ("down", 13), ("the", 14), ("road", 15)]
            ),
            (
                "singing every single note", 18,
                [("singing", 18), ("every", 19), ("single", 20), ("note", 21)]
            ),
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 60)
        )

        // Printed Em/D/C/G at the second fret sound as F♯m/E/D/A. The intro
        // chord and the verse's first chord are both F♯m and run together,
        // which is one chord, printed once.
        XCTAssertEqual(
            result.chords.segments.compactMap { $0.chord?.symbol(preferringFlats: false) },
            ["F♯m", "E", "D", "A"]
        )
        // The intro has no words, so it precedes the first sung line; the rest
        // land on the words they were written over.
        let starts = result.chords.segments.map(\.start)
        XCTAssertLessThan(starts[0], 12)
        XCTAssertEqual(Array(starts.dropFirst()), [15, 19, 21])
    }

    /// A chord printed in the gap before a word belongs to that word, not to
    /// the one it happens to trail.
    func testAChordPrintedJustBeforeAWordLandsOnIt() throws {
        let document = UserChordParser.parse(
            """
            C               G
            walking down the road
            """
        )
        let song = lyrics([
            (
                "walking down the road", 12,
                [("walking", 12), ("down", 13), ("the", 14), ("road", 15)]
            )
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 30)
        )

        // Column 16 falls in the space between "the" and "road".
        XCTAssertEqual(result.chords.segments.map(\.start), [12, 15])
    }

    /// A bar number in a chart that also has words counts bars *of that
    /// section*, not bars of the recording. Read absolutely, a written-out
    /// interlude was sent back to the first few seconds of the song and then
    /// stacked on top of itself by the ordering pass.
    func testWrittenOutBarsLandBetweenTheWordsAroundThem() throws {
        let document = UserChordParser.parse(
            """
            [Verse]
            C
            first line of the song

            [Interlude]
            | G | Am | F | C |

            [Verse]
            D
            last line of the song
            """
        )
        let song = lyrics([
            ("first line of the song", 10, []),
            ("last line of the song", 50, []),
        ])
        let grid = BeatGrid.uniform(
            bpm: 120,
            firstDownbeat: 0,
            beatsPerBar: 4,
            duration: 90
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: grid, duration: 90)
        )

        let bars = result.chords.segments.filter {
            $0.start > 10 && $0.start < 50
        }
        XCTAssertEqual(bars.count, 4)
        // Spread across the gap rather than crushed against its start.
        let spread = try XCTUnwrap(bars.last?.start) - (try XCTUnwrap(bars.first?.start))
        XCTAssertGreaterThan(spread, 10)
    }

    /// A chart that is nothing but bars has no words to place it by, so its
    /// bar numbers are the recording's bar numbers.
    func testAPureBarChartStillUsesAbsoluteBars() throws {
        let document = UserChordParser.parse("| C . G . | Am . F . |")
        let grid = BeatGrid.uniform(
            bpm: 120,
            firstDownbeat: 0,
            beatsPerBar: 4,
            duration: 8
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: nil, grid: grid, duration: 8)
        )

        XCTAssertEqual(result.chords.segments.map(\.start), [0, 1, 2, 3])
    }

    /// Without word timings, a line's words must not be smeared across the
    /// silence that follows it.
    func testWordsAreNotSmearedAcrossAnInstrumentalGap() throws {
        let document = UserChordParser.parse(
            """
            C            G
            one two three four
            """
        )
        // Fifty seconds until anything else is sung.
        let song = lyrics([
            ("one two three four", 10, []),
            ("the next line entirely", 60, []),
        ])

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: song, grid: nil, duration: 120)
        )

        let second = try XCTUnwrap(result.chords.segments.last?.start)
        XCTAssertGreaterThan(second, 10)
        XCTAssertLessThan(second, 16)
    }

    /// A chart written for a differently tuned guitar places every chord
    /// correctly and still sounds wrong. Say so; do not move it silently.
    func testAChartInAnotherKeyIsReportedRatherThanCorrected() throws {
        let document = UserChordParser.parse(
            """
            C
            first line of the song

            F
            last line of the song
            """
        )
        let song = lyrics([
            ("first line of the song", 5, []),
            ("last line of the song", 35, []),
        ])
        // The recording is a semitone below the chart throughout.
        let reference = SongChords(
            segments: [
                ChordSegment(start: 0, end: 30, chord: Chord(root: 11, quality: .major), confidence: 0.8),
                ChordSegment(start: 30, end: 60, chord: Chord(root: 4, quality: .major), confidence: 0.8),
            ],
            confidence: 0.8
        )

        let asWritten = try XCTUnwrap(
            UserChordAligner.align(
                document, lyrics: song, grid: nil, duration: 60, reference: reference
            )
        )

        XCTAssertEqual(asWritten.alignment.suggestedPitchOffset, -1)
        XCTAssertTrue(asWritten.alignment.suggestsDifferentPitch)
        XCTAssertTrue(asWritten.alignment.warnings.contains { $0.kind == .pitchMismatch })
        // Nothing was moved without being asked.
        XCTAssertEqual(
            asWritten.chords.segments.compactMap { $0.chord?.root },
            [0, 5]
        )

        let matched = try XCTUnwrap(
            UserChordAligner.align(
                document, lyrics: song, grid: nil, duration: 60,
                reference: reference, pitchOffset: -1
            )
        )

        XCTAssertEqual(matched.chords.segments.compactMap { $0.chord?.root }, [11, 4])
        XCTAssertFalse(matched.alignment.suggestsDifferentPitch)
        XCTAssertEqual(matched.alignment.pitchOffset, -1)
        XCTAssertGreaterThan(
            try XCTUnwrap(matched.alignment.pitchAgreement),
            try XCTUnwrap(asWritten.alignment.pitchAgreement)
        )
    }

    /// A chart already at the recording's pitch must not be nudged.
    func testAMatchingChartIsLeftAlone() throws {
        let document = UserChordParser.parse(
            """
            C
            first line of the song
            """
        )
        let song = lyrics([("first line of the song", 5, [])])
        let reference = SongChords(
            segments: [
                ChordSegment(start: 0, end: 60, chord: Chord(root: 0, quality: .major), confidence: 0.8)
            ],
            confidence: 0.8
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(
                document, lyrics: song, grid: nil, duration: 60, reference: reference
            )
        )

        XCTAssertNil(result.alignment.suggestedPitchOffset)
        XCTAssertFalse(result.alignment.suggestsDifferentPitch)
    }

    /// The alignment file is user data and predates these fields.
    func testOlderAlignmentsWithoutPitchFieldsStillDecode() throws {
        let json = """
        {
          "version": 1, "parseCoverage": 1, "lyricAnchorCoverage": 1,
          "beatCoverage": 0, "confidence": 0.5, "usedEstimatedPlacements": true,
          "likelyArrangementMismatch": false, "warnings": [],
          "alignedAt": 774100000
        }
        """
        let decoded = try JSONDecoder().decode(
            ChordChartAlignment.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(decoded.pitchOffset, 0)
        XCTAssertFalse(decoded.suggestsDifferentPitch)
    }

    private static func evidence(
        _ pitches: [Int],
        at time: TimeInterval
    ) -> BeatChordEvidence {
        var chroma = [Float](repeating: 0, count: 12)
        for pitch in pitches { chroma[pitch] = 1 }
        return BeatChordEvidence(
            start: time,
            end: time + 1,
            harmonicChroma: chroma,
            bassChroma: chroma,
            energy: 1
        )
    }
}

final class UserChordCollectionTests: XCTestCase {
    func testCollectionCodableRoundTripKeepsIndependentSelection() throws {
        let id = UUID()
        let chart = UserChordChart(
            id: id,
            name: "My chart",
            origin: .pasted,
            sourceMetadata: ImportedChordMetadata(),
            document: UserChordParser.parse("C G"),
            chords: SongChords()
        )
        let collection = UserChordCollection(
            selectedSource: .user(id),
            charts: [chart]
        )

        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(UserChordCollection.self, from: data)

        XCTAssertEqual(decoded, collection)
        XCTAssertEqual(decoded.selectedSource, .user(id))
    }

    func testUserChartsAreUserDataButNotAnalysisArtifacts() {
        XCTAssertTrue(SongStorage.songFilenames.contains(SongStorage.userChordsFilename))
        XCTAssertFalse(SongStorage.analysisFilenames.contains(SongStorage.userChordsFilename))
    }
}

/// What the two stores owe each other.
///
/// The whole point of keeping detected and imported charts in separate files is
/// that neither can reach the other. That is a claim about `ChordStore`'s
/// mutation surface, so it is tested there rather than inferred from the
/// storage layout.
@MainActor
final class ChordStoreIsolationTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    private func makeTrack() -> LocalTrack {
        LocalTrack(
            id: UUID(),
            title: "Fixture",
            files: [:],
            createdAt: Date(),
            sourceURL: nil,
            sourceOriginalID: nil,
            separationModel: .htdemucs,
            folderURL: library.folder(named: UUID().uuidString)
        )
    }

    private func detectedChart() -> SongChords {
        SongChords(
            segments: [
                ChordSegment(start: 0, end: 5, chord: Chord(root: 0, quality: .major), confidence: 0.8),
                ChordSegment(start: 5, end: 10, chord: Chord(root: 7, quality: .major), confidence: 0.8),
            ],
            key: MusicalKey(tonic: 0, isMinor: false),
            confidence: 0.8
        )
    }

    private func openStore(with track: LocalTrack, detected: SongChords?) throws -> ChordStore {
        if let detected {
            try track.songStorage.write(detected, to: SongChords.filename)
        }
        let store = ChordStore()
        store.open(track: track, duration: 30)
        return store
    }

    private func addChart(
        to store: ChordStore,
        named name: String,
        text: String = "[C]alpha [F]beta"
    ) throws -> UserChordChart {
        let lyrics = SongLyrics(
            source: .manual,
            lines: [
                LyricLine(
                    text: "alpha beta",
                    start: 4,
                    words: [LyricWord(text: "alpha", start: 4), LyricWord(text: "beta", start: 6)]
                )
            ]
        )
        return try XCTUnwrap(
            store.addUserChart(
                document: UserChordParser.parse(text),
                origin: .pasted,
                name: name,
                lyrics: lyrics,
                grid: nil
            )
        )
    }

    func testDetectedAndImportedChartsCoexistAndSwitch() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())
        let chart = try addChart(to: store, named: "My chart")

        XCTAssertEqual(store.userCollection.selectedSource, .user(chart.id))
        XCTAssertEqual(store.chords?.segments.count, 2)
        XCTAssertTrue(store.hasAlternativeCharts)

        store.select(.detected)
        XCTAssertEqual(store.chords?.segments.first?.chord, Chord(root: 0, quality: .major))
        XCTAssertNotNil(store.detectedChords)
    }

    /// Correcting the chart on screen must not reach into the one that is not.
    func testCorrectingOneChartCannotAlterAnother() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())
        let chart = try addChart(to: store, named: "My chart")
        let detectedBefore = try XCTUnwrap(store.detectedChords)

        let importedSegment = try XCTUnwrap(store.chords?.segments.first)
        store.correct(importedSegment.id, to: Chord(root: 2, quality: .minor))

        XCTAssertEqual(store.detectedChords, detectedBefore)
        let corrected = try XCTUnwrap(
            store.userCollection.charts.first { $0.id == chart.id }?.chords?.segments.first
        )
        XCTAssertEqual(corrected.chord, Chord(root: 2, quality: .minor))
        XCTAssertTrue(corrected.isUserEdited)

        store.select(.detected)
        let detectedSegment = try XCTUnwrap(store.chords?.segments.first)
        store.correct(detectedSegment.id, to: Chord(root: 5, quality: .major))

        let importedAfter = try XCTUnwrap(
            store.userCollection.charts.first { $0.id == chart.id }?.chords?.segments.first
        )
        XCTAssertEqual(importedAfter.chord, Chord(root: 2, quality: .minor))
    }

    /// Detection writes `chords.json` and nothing else. Removing the detected
    /// chart is the same promise from the other direction.
    func testRemovingDetectedAnalysisLeavesImportedChartsIntact() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())
        let chart = try addChart(to: store, named: "My chart")

        store.clearDetected()

        XCTAssertNil(store.detectedChords)
        XCTAssertEqual(store.userCollection.charts.count, 1)
        XCTAssertEqual(store.userCollection.selectedSource, .user(chart.id))
        XCTAssertNotNil(store.chords)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: track.songStorage.url(for: SongChords.filename).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: track.songStorage.url(for: SongStorage.userChordsFilename).path
            )
        )
    }

    func testRemovingOneImportedChartLeavesTheOthers() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: nil)
        let first = try addChart(to: store, named: "First")
        let second = try addChart(to: store, named: "Second")

        store.removeUserChart(id: second.id)

        XCTAssertEqual(store.userCollection.charts.map(\.id), [first.id])
        XCTAssertEqual(store.userCollection.selectedSource, .user(first.id))
    }

    /// Two charts imported under one name must stay distinguishable.
    func testDuplicateNamesAreMadeUnique() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: nil)
        _ = try addChart(to: store, named: "My chart")
        let second = try addChart(to: store, named: "My chart")

        XCTAssertEqual(second.name, "My chart 2")
    }

    func testSelectionSurvivesReopeningTheSong() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())
        let chart = try addChart(to: store, named: "My chart")
        store.select(.detected)
        store.close()

        let reopened = try openStore(with: track, detected: nil)
        XCTAssertEqual(reopened.userCollection.selectedSource, .detected)
        XCTAssertEqual(reopened.userCollection.charts.map(\.id), [chart.id])

        reopened.select(.user(chart.id))
        reopened.close()

        let again = try openStore(with: track, detected: nil)
        XCTAssertEqual(again.userCollection.selectedSource, .user(chart.id))
    }

    /// A selection pointing at something that is gone must repair itself once,
    /// and stay repaired.
    func testSelectionFallsBackWhenTheSelectedChartDisappears() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())
        let chart = try addChart(to: store, named: "My chart")
        store.close()

        // Something removed the chart from under the stored selection.
        var collection = try XCTUnwrap(
            track.songStorage.read(
                UserChordCollection.self,
                from: SongStorage.userChordsFilename
            )
        )
        collection.charts.removeAll()
        try track.songStorage.write(collection, to: SongStorage.userChordsFilename)

        let reopened = try openStore(with: track, detected: nil)
        XCTAssertEqual(reopened.userCollection.selectedSource, .detected)
        XCTAssertNotNil(reopened.chords)

        let persisted = try XCTUnwrap(
            track.songStorage.read(
                UserChordCollection.self,
                from: SongStorage.userChordsFilename
            )
        )
        XCTAssertEqual(persisted.selectedSource, .detected)
        XCTAssertNotEqual(persisted.selectedSource, .user(chart.id))
    }

    /// A library from before the feature existed has no user file at all.
    func testALibraryWithOnlyDetectedChordsBehavesAsBefore() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: detectedChart())

        XCTAssertEqual(store.userCollection.selectedSource, .detected)
        XCTAssertTrue(store.userCollection.charts.isEmpty)
        XCTAssertFalse(store.hasAlternativeCharts)
        XCTAssertEqual(store.chords?.segments.count, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: track.songStorage.url(for: SongStorage.userChordsFilename).path
            )
        )
    }

    /// Re-aligning an imported chart rebuilds its timing but keeps the chords
    /// the user fixed by hand.
    func testRealignmentPreservesCorrectionsWithinThatChart() throws {
        let track = makeTrack()
        let store = try openStore(with: track, detected: nil)
        let chart = try addChart(to: store, named: "My chart")
        let segment = try XCTUnwrap(store.chords?.segments.first)
        store.correct(segment.id, to: Chord(root: 3, quality: .minorSeventh))

        store.realignUserChart(id: chart.id, lyrics: nil, grid: nil)

        let chords = try XCTUnwrap(
            store.userCollection.charts.first { $0.id == chart.id }?.chords
        )
        XCTAssertTrue(chords.segments.contains {
            $0.isUserEdited && $0.chord == Chord(root: 3, quality: .minorSeventh)
        })
    }
}
