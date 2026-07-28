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
}

final class UserChordAlignmentTests: XCTestCase {
    func testWordTimedLyricsPlaceChordsOnMatchedWords() throws {
        let document = UserChordParser.parse("[C]alpha [F]beta")
        let lyrics = SongLyrics(
            source: .manual,
            lines: [
                LyricLine(
                    text: "alpha beta",
                    start: 4,
                    end: 8,
                    words: [
                        LyricWord(text: "alpha", start: 4),
                        LyricWord(text: "beta", start: 6),
                    ]
                )
            ]
        )

        let result = try XCTUnwrap(
            UserChordAligner.align(document, lyrics: lyrics, grid: nil, duration: 10)
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
        func evidence(_ pitches: [Int], at time: TimeInterval) -> BeatChordEvidence {
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
        let beats = [
            evidence([0, 2, 4, 7, 11], at: 0),
            evidence([0, 2, 4, 7, 11], at: 1),
            evidence([5, 8, 0, 3], at: 2),
            evidence([5, 8, 0, 3], at: 3),
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
