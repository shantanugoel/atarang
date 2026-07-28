import XCTest
@testable import Atarang

/// Writes a chart out the way chart sites write them, so it can be read back
/// in and checked against what it was made from.
///
/// A chart pasted from the web tells you nothing about *why* an import came out
/// wrong: there is nothing to compare it to except the detector, which is
/// itself only mostly right. Rendering a known chart and reading it back gives
/// an exact answer — every chord's true time is known, so the error is the
/// aligner's alone.
///
/// The rendering is deliberately awkward in the ways real pages are: columns
/// come from the clock rather than from word indices, the chart's wording drifts
/// from the recording's, sections repeat verbatim, and lines end with CRLF.
struct ChartRenderer {
    enum Instrumental {
        /// `| Em | Em | D | D |`, the way a written-out interlude appears.
        case bars
        /// A bare chord line with nothing under it.
        case looseChords
    }

    /// Semitones the chart is written away from the recording, as a capo the
    /// transcriber assumed or a guitar tuned down.
    var transpose = 0
    /// Written as a `Capo: n` line and reflected in the printed shapes.
    var capo = 0
    var instrumental = Instrumental.bars
    var lineEnding = "\r\n"
    /// Chart wording drifts from the recording's, as it always does.
    var perturbsWording = true
    /// Lines the chart never printed, as a condensed page omits them.
    var omitsLineEvery = 0

    func render(
        chords: SongChords,
        lyrics: SongLyrics,
        sections: [Int: String],
        duration: TimeInterval
    ) -> String {
        var lines: [String] = ["Artist: Synthetic Fixture"]
        if capo > 0 { lines.append("Capo: \(capo)\(ordinalSuffix(capo)) fret") }
        lines.append("Tuning: E A D G B e")
        lines.append("")

        // Printed shape = what sounds, moved to the chart's pitch, then down
        // by the capo the player is told to fit.
        let printedShift = transpose - capo
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isSection }
        let omitted: Set<Int> = omitsLineEvery > 1
            ? Set(sung.enumerated().filter { $0.offset % omitsLineEvery == 0 }.map(\.element))
            : []

        // Which chords each sung line covers — including the lines this chart
        // does not print, whose chords it simply does not have.
        var covered = Set<Int>()
        var perLine: [Int: [Int]] = [:]
        for index in sung {
            guard let start = lyrics.effectiveStart(of: lyrics.lines[index]) else { continue }
            let end = lineEnd(index, in: lyrics, duration: duration)
            for (offset, segment) in chords.segments.enumerated()
            where segment.start >= start && segment.start < end {
                perLine[index, default: []].append(offset)
                covered.insert(offset)
            }
        }

        // Everything the words never covered is the band playing alone. Blocks
        // are emitted in the order they happen, because a chart is read top to
        // bottom and that order is the song's.
        enum Block { case line(Int, Int); case instrumental([Int]) }
        var blocks: [(start: TimeInterval, block: Block)] = []
        for (position, index) in sung.enumerated() where !omitted.contains(index) {
            guard let start = lyrics.effectiveStart(of: lyrics.lines[index]) else { continue }
            blocks.append((start, .line(index, position)))
        }
        for run in runs(of: chords.segments.indices.filter { !covered.contains($0) }) {
            guard let first = run.first else { continue }
            blocks.append((chords.segments[first].start, .instrumental(run)))
        }
        blocks.sort { $0.start < $1.start }

        var lastSection: String?
        for entry in blocks {
            switch entry.block {
            case .line(let index, let position):
                if let label = sections[index], label != lastSection {
                    lines.append("")
                    lines.append("[\(label)]")
                    lastSection = label
                }
                let start = lyrics.effectiveStart(of: lyrics.lines[index]) ?? 0
                let end = lineEnd(index, in: lyrics, duration: duration)
                let text = perturbsWording
                    ? drift(lyrics.lines[index].text, seed: position)
                    : lyrics.lines[index].text
                guard let indices = perLine[index], !indices.isEmpty else {
                    lines.append(text)
                    continue
                }
                // The column is where the chord falls in the line's own clock,
                // which is how a transcriber lines a chord up over a syllable.
                var chordLine = ""
                for offset in indices {
                    let fraction = (chords.segments[offset].start - start) / max(0.01, end - start)
                    let column = min(
                        max(0, Int((fraction * Double(text.count)).rounded())),
                        max(0, text.count - 1)
                    )
                    let symbol = printed(chords.segments[offset].chord, shift: printedShift)
                    if chordLine.count > column {
                        chordLine += " " + symbol
                    } else {
                        chordLine += String(repeating: " ", count: column - chordLine.count) + symbol
                    }
                }
                lines.append(chordLine)
                lines.append(text)

            case .instrumental(let run):
                let symbols = run.map { printed(chords.segments[$0].chord, shift: printedShift) }
                lines.append("")
                lines.append("[Interlude]")
                lastSection = "Interlude"
                switch instrumental {
                case .bars:
                    lines.append("| " + symbols.joined(separator: " | ") + " |")
                case .looseChords:
                    lines.append(symbols.joined(separator: "  "))
                }
            }
        }
        return lines.joined(separator: lineEnding) + lineEnding
    }

    private func printed(_ chord: Chord?, shift: Int) -> String {
        guard let chord else { return "N.C." }
        return chord.transposed(by: shift).symbol(preferringFlats: false)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
    }

    /// How long the line is actually sung for.
    ///
    /// Not "until the next line starts". A transcriber writes chords over the
    /// words while the words are being sung; whatever plays during the pause
    /// afterwards is written out separately as bars. Treating the gap as part
    /// of the line would spread the chords of a four-second phrase over the
    /// twenty seconds before the next one.
    private func lineEnd(
        _ index: Int,
        in lyrics: SongLyrics,
        duration: TimeInterval
    ) -> TimeInterval {
        let start = lyrics.effectiveStart(atIndex: index) ?? 0
        // An explicit end is the source saying where the words stop; believe
        // it. Only when there is none is the span estimated from the words.
        if let end = lyrics.lines[index].end { return end }
        if let last = lyrics.lines[index].words.last?.start { return last + 0.6 }
        let words = lyrics.lines[index].text.split(whereSeparator: \.isWhitespace).count
        let sung = start + Double(max(1, words)) * 0.5
        for next in (index + 1)..<lyrics.lines.count {
            guard !lyrics.lines[next].isSection,
                  let nextStart = lyrics.effectiveStart(atIndex: next) else { continue }
            return min(nextStart, sung)
        }
        return min(duration, sung)
    }

    /// Small differences of the kind that separate a chart page's words from a
    /// caption track's: casing, punctuation, an occasional extra word.
    private func drift(_ text: String, seed: Int) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count > 3 else { return text }
        if seed % 3 == 0 { words[0] = words[0].capitalized }
        if seed % 4 == 0 { words.insert("oh", at: 1) }
        if seed % 5 == 0, words.count > 4 { words.removeLast() }
        return words.joined(separator: " ") + (seed % 2 == 0 ? "," : "")
    }

    private func runs(of indices: [Int]) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for index in indices {
            if let last = current.last, index != last + 1 {
                result.append(current)
                current = []
            }
            current.append(index)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private func ordinalSuffix(_ value: Int) -> String {
        switch value {
        case 1: "st"
        case 2: "nd"
        case 3: "rd"
        default: "th"
        }
    }
}

/// A song built to order, so both the chart and the truth are known.
struct SyntheticSong {
    var chords: SongChords
    var lyrics: SongLyrics
    var grid: BeatGrid
    var sections: [Int: String]
    var duration: TimeInterval

    /// - Parameters:
    ///   - progression: repeated through each section.
    ///   - structure: section name and how many lines it sings.
    ///   - instrumentalAfter: sections after which the band plays alone.
    ///   - wordTimings: whether the song's lyrics carry a time per word. Line
    ///     timings alone leave the aligner interpolating inside each line.
    ///   - evenChords: false places chord changes irregularly within a line,
    ///     which is what a real song does and what interpolation cannot know.
    static func make(
        progression: [Chord],
        structure: [(name: String, lines: Int)],
        bpm: Double = 100,
        chordsPerLine: Int = 2,
        instrumentalAfter: Set<Int> = [],
        instrumentalBars: Int = 4,
        wordTimings: Bool = false,
        evenChords: Bool = true
    ) -> SyntheticSong {
        let beat = 60 / bpm
        let lineLength = beat * 8
        var segments: [ChordSegment] = []
        var lyricLines: [LyricLine] = []
        var sections: [Int: String] = [:]
        var time = beat * 4
        var word = 0
        var chordIndex = 0

        for (sectionIndex, section) in structure.enumerated() {
            sections[lyricLines.count] = section.name
            for lineNumber in 0..<section.lines {
                let start = time
                // Words are drawn from a fixed vocabulary so that repeated
                // sections repeat verbatim, as a chorus does.
                let words = (0..<6).map { position in
                    Self.vocabulary[
                        (section.name.count * 7 + lineNumber * 6 + position) % Self.vocabulary.count
                    ]
                }
                let text = words.joined(separator: " ")
                // Words are sung evenly only in a fixture. `evenChords: false`
                // spaces them the way a singer does — which is the case where
                // interpolating inside a line stops being able to guess right,
                // and where a time per word starts to matter.
                let fractions: [Double]
                if evenChords {
                    fractions = (0..<words.count).map { Double($0) / Double(words.count) }
                } else {
                    let gaps = (0..<words.count).map {
                        0.5 + Double((lineNumber + $0) % 4) * 0.5
                    }
                    let total = gaps.reduce(0, +)
                    var running = 0.0
                    fractions = gaps.map { gap in
                        defer { running += gap }
                        return running / total
                    }
                }
                lyricLines.append(
                    LyricLine(
                        text: text,
                        start: start,
                        end: start + lineLength,
                        words: wordTimings
                            ? zip(words, fractions).map { word, fraction in
                                LyricWord(text: word, start: start + fraction * lineLength)
                            }
                            : []
                    )
                )
                // A chart writes its chords over syllables, so a chord change
                // lands on a word rather than at an even fraction of the line.
                let step = max(1, words.count / max(1, chordsPerLine))
                let onWords = (0..<chordsPerLine).map { min(words.count - 1, $0 * step) }
                for (position, wordIndex) in onWords.enumerated() {
                    let next = position + 1 < onWords.count
                        ? fractions[onWords[position + 1]]
                        : 1
                    segments.append(
                        ChordSegment(
                            start: start + fractions[wordIndex] * lineLength,
                            end: start + next * lineLength,
                            chord: progression[chordIndex % progression.count],
                            confidence: 0.9
                        )
                    )
                    chordIndex += 1
                }
                time += lineLength
                word += 6
            }
            if instrumentalAfter.contains(sectionIndex) {
                for bar in 0..<instrumentalBars {
                    segments.append(
                        ChordSegment(
                            start: time + Double(bar) * beat * 4,
                            end: time + Double(bar + 1) * beat * 4,
                            chord: progression[chordIndex % progression.count],
                            confidence: 0.9
                        )
                    )
                    chordIndex += 1
                }
                time += Double(instrumentalBars) * beat * 4
            }
        }

        let duration = time + beat * 4
        var chords = SongChords(
            segments: segments,
            key: MusicalKey(tonic: progression[0].root, isMinor: progression[0].quality.base == .minor),
            confidence: 0.9
        )
        chords.sanitize(duration: duration)
        return SyntheticSong(
            chords: chords,
            lyrics: SongLyrics(source: .manual, lines: lyricLines),
            grid: BeatGrid.uniform(
                bpm: bpm,
                firstDownbeat: 0,
                beatsPerBar: 4,
                duration: duration
            ),
            sections: sections,
            duration: duration
        )
    }

    private static let vocabulary = [
        "morning", "river", "shadow", "window", "highway", "silver", "letter",
        "August", "harbour", "lantern", "quiet", "traveller", "distance",
        "orchard", "winter", "signal", "paper", "engine", "meadow", "thunder",
    ]
}

final class ChartRoundTripTests: XCTestCase {
    /// The share of the song where the rebuilt chart names the same chord as
    /// the chart it was rendered from.
    private func accuracy(
        _ produced: SongChords,
        _ truth: SongChords,
        duration: TimeInterval
    ) -> Double {
        var samples = 0
        var agreed = 0
        var time = 0.0
        while time < duration {
            defer { time += 0.1 }
            let mine = produced.segment(at: time)?.chord
            let theirs = truth.segment(at: time)?.chord
            guard theirs != nil else { continue }
            samples += 1
            if mine == theirs { agreed += 1 }
        }
        return samples == 0 ? 0 : Double(agreed) / Double(samples)
    }

    private func roundTrip(
        _ song: SyntheticSong,
        renderer: ChartRenderer = ChartRenderer(),
        pitchOffset: Int = 0
    ) throws -> (accuracy: Double, alignment: ChordChartAlignment) {
        let text = renderer.render(
            chords: song.chords,
            lyrics: song.lyrics,
            sections: song.sections,
            duration: song.duration
        )
        let document = UserChordParser.parse(text)
        let result = try XCTUnwrap(
            UserChordAligner.align(
                document,
                lyrics: song.lyrics,
                grid: song.grid,
                duration: song.duration,
                reference: song.chords,
                pitchOffset: pitchOffset
            ),
            "the chart produced nothing"
        )
        return (
            accuracy(result.chords, song.chords, duration: song.duration),
            result.alignment
        )
    }

    private func chord(_ root: Int, _ quality: ChordQuality) -> Chord {
        Chord(root: root, quality: quality)
    }

    // MARK: - Genres, as structures

    func testFourChordPop() throws {
        let song = SyntheticSong.make(
            progression: [chord(0, .major), chord(7, .major), chord(9, .minor), chord(5, .major)],
            structure: [("Verse 1", 4), ("Chorus", 4), ("Verse 2", 4), ("Chorus", 4)]
        )
        let outcome = try roundTrip(song)
        XCTAssertGreaterThan(outcome.accuracy, 0.85)
    }

    func testBalladWithWrittenOutInterludeAndSolo() throws {
        let song = SyntheticSong.make(
            progression: [chord(4, .minor), chord(2, .suspendedSecond), chord(9, .suspendedFourth), chord(0, .major)],
            structure: [("Verse 1", 4), ("Chorus", 4), ("Verse 2", 4), ("Chorus", 4), ("Outro", 2)],
            bpm: 76,
            instrumentalAfter: [1, 3],
            instrumentalBars: 8
        )
        let outcome = try roundTrip(song)
        XCTAssertGreaterThan(outcome.accuracy, 0.85)
    }

    func testTwelveBarBluesWithLooseChordLines() throws {
        let song = SyntheticSong.make(
            progression: [
                chord(9, .dominantSeventh), chord(2, .dominantSeventh),
                chord(4, .dominantSeventh), chord(9, .dominantSeventh),
            ],
            structure: [("Verse 1", 6), ("Solo", 2), ("Verse 2", 6)],
            bpm: 120,
            chordsPerLine: 1,
            instrumentalAfter: [0, 1],
            instrumentalBars: 12
        )
        var renderer = ChartRenderer()
        renderer.instrumental = .looseChords
        let outcome = try roundTrip(song, renderer: renderer)
        XCTAssertGreaterThan(outcome.accuracy, 0.80)
    }

    func testJazzRichVocabularySurvivesTheRoundTrip() throws {
        let song = SyntheticSong.make(
            progression: [
                chord(2, .minorNinth), chord(7, .dominantSeventh),
                chord(0, .majorNinth), chord(11, .halfDiminished),
                chord(4, .augmented), chord(9, .minorSeventh),
            ],
            structure: [("Head", 4), ("Solo", 4), ("Head", 4)],
            bpm: 132,
            chordsPerLine: 3
        )
        let outcome = try roundTrip(song)
        XCTAssertGreaterThan(outcome.accuracy, 0.80)
    }

    func testFolkChartWrittenWithACapo() throws {
        let song = SyntheticSong.make(
            progression: [chord(2, .major), chord(9, .major), chord(11, .minor), chord(7, .major)],
            structure: [("Verse 1", 4), ("Chorus", 3), ("Verse 2", 4)],
            bpm: 92
        )
        var renderer = ChartRenderer()
        renderer.capo = 2
        let outcome = try roundTrip(song, renderer: renderer)
        XCTAssertGreaterThan(outcome.accuracy, 0.85)
    }

    /// The chorus is sung three times to the same words. Each has to find its
    /// own occurrence.
    func testChorusRepeatedThreeTimes() throws {
        let song = SyntheticSong.make(
            progression: [chord(5, .major), chord(0, .major), chord(7, .major), chord(2, .minor)],
            structure: [
                ("Verse 1", 3), ("Chorus", 3), ("Verse 2", 3),
                ("Chorus", 3), ("Bridge", 2), ("Chorus", 3),
            ]
        )
        let outcome = try roundTrip(song)
        XCTAssertGreaterThan(outcome.accuracy, 0.80)
    }

    /// A condensed page that never printed some of what is sung.
    ///
    /// A third of the lines are missing, and with them a third of the chart's
    /// chords, so the timeline cannot agree more than about two thirds of the
    /// time however well it is aligned. What is being checked is that the lines
    /// the chart *did* print still land correctly rather than being dragged out
    /// of place by the holes between them.
    func testChartThatOmitsLinesTheRecordingSings() throws {
        let song = SyntheticSong.make(
            progression: [chord(7, .major), chord(4, .minor), chord(0, .major), chord(2, .major)],
            structure: [("Verse 1", 6), ("Chorus", 4), ("Verse 2", 6)]
        )
        var renderer = ChartRenderer()
        renderer.omitsLineEvery = 3
        let outcome = try roundTrip(song, renderer: renderer)
        XCTAssertGreaterThan(outcome.accuracy, 0.55)
        XCTAssertLessThan(outcome.accuracy, 0.75, "above the structural ceiling — check the metric")
    }

    /// The Metallica case, in miniature: a chart written a semitone above the
    /// recording. Reported, then corrected on request.
    func testChartWrittenForADownTunedGuitar() throws {
        let song = SyntheticSong.make(
            progression: [chord(3, .minor), chord(1, .suspendedSecond), chord(8, .suspendedFourth), chord(11, .major)],
            structure: [("Verse 1", 4), ("Chorus", 4), ("Verse 2", 4), ("Chorus", 4)]
        )
        var renderer = ChartRenderer()
        renderer.transpose = 1

        let asWritten = try roundTrip(song, renderer: renderer)
        XCTAssertEqual(asWritten.alignment.suggestedPitchOffset, -1)
        XCTAssertTrue(asWritten.alignment.suggestsDifferentPitch)
        XCTAssertLessThan(asWritten.accuracy, 0.1)

        let matched = try roundTrip(song, renderer: renderer, pitchOffset: -1)
        XCTAssertFalse(matched.alignment.suggestsDifferentPitch)
        XCTAssertGreaterThan(matched.accuracy, 0.85)
    }

    /// What actually limits a real import.
    ///
    /// The same song and the same chart, once with a time per word and once
    /// with only a time per line. Everything else is held equal, so the
    /// difference is the resolution of the lyrics rather than anything the
    /// aligner does — which is why a real song whose captions are line-timed
    /// reconstructs far less exactly than these fixtures otherwise suggest.
    func testWordTimingsAreWhatMakePlacementExact() throws {
        func song(wordTimings: Bool) -> SyntheticSong {
            SyntheticSong.make(
                progression: [
                    chord(4, .minor), chord(2, .suspendedSecond),
                    chord(9, .suspendedFourth), chord(0, .major),
                ],
                structure: [("Verse 1", 5), ("Chorus", 4), ("Verse 2", 5), ("Chorus", 4)],
                bpm: 84,
                chordsPerLine: 3,
                wordTimings: wordTimings,
                evenChords: false
            )
        }

        let lineTimed = try roundTrip(song(wordTimings: false))
        let wordTimed = try roundTrip(song(wordTimings: true))

        // Word timings help, but by less than expected: mapping the chord's
        // column to a word *index* and interpolating by that index already
        // recovers most of what per-word times would give. Worth knowing before
        // anyone spends effort sourcing word-timed lyrics to fix an import.
        XCTAssertGreaterThanOrEqual(wordTimed.accuracy, lineTimed.accuracy - 0.02)
        XCTAssertGreaterThan(wordTimed.accuracy, 0.80)
        XCTAssertGreaterThan(lineTimed.accuracy, 0.80)
    }

    /// Unix line endings must give the same answer as the CRLF a browser
    /// paste produces.
    func testLineEndingsDoNotChangeTheResult() throws {
        let song = SyntheticSong.make(
            progression: [chord(0, .major), chord(5, .major), chord(7, .major), chord(9, .minor)],
            structure: [("Verse 1", 4), ("Chorus", 4)]
        )
        var unix = ChartRenderer()
        unix.lineEnding = "\n"

        let crlf = try roundTrip(song)
        let lf = try roundTrip(song, renderer: unix)

        XCTAssertEqual(crlf.accuracy, lf.accuracy, accuracy: 0.02)
        XCTAssertGreaterThan(lf.accuracy, 0.85)
    }
}
