import XCTest
@testable import Atarang

/// The parts of the lyrics feature that are easy to get wrong and invisible
/// when they are: what a hostile file parses into, which line the playhead is
/// inside, and whether a round trip through `.lrc` says the same thing twice.
final class LyricsFormatTests: XCTestCase {
    // MARK: - LRC

    func testParsesLineTagsAndText() {
        let lyrics = LyricsFormat.parseLRC("""
        [ti:Test Song]
        [ar:Somebody]
        [00:12.34]First line
        [01:05.00]Second line
        """)
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[0].text, "First line")
        XCTAssertEqual(lyrics.lines[0].start ?? 0, 12.34, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[1].start ?? 0, 65, accuracy: 0.001)
        XCTAssertEqual(lyrics.attribution, "Test Song — Somebody")
        XCTAssertEqual(lyrics.source, .lrcFile)
    }

    func testParsesWordTags() {
        let lyrics = LyricsFormat.parseLRC("[00:10.00]<00:10.00>Hello <00:10.60>world")
        let line = try? XCTUnwrap(lyrics.lines.first)
        XCTAssertEqual(line?.text, "Hello world")
        XCTAssertEqual(line?.words.count, 2)
        XCTAssertEqual(line?.words.last?.text, "world")
        XCTAssertEqual(line?.words.last?.start ?? 0, 10.6, accuracy: 0.001)
    }

    /// A bracket that is not a timestamp is not an error, and `[Chorus]` is the
    /// reason that matters: it is structure, and it becomes a saved section.
    func testBracketedWordBecomesSectionLabel() {
        let lyrics = LyricsFormat.parseLRC("""
        [00:00.00][Verse 1]
        [00:04.00]Words
        [00:30.00][Chorus]
        """)
        XCTAssertEqual(lyrics.lines.count, 3)
        XCTAssertEqual(lyrics.lines[0].sectionLabel, "Verse 1")
        XCTAssertNil(lyrics.lines[1].sectionLabel)
        XCTAssertEqual(lyrics.lines[2].sectionLabel, "Chorus")

        let sections = lyrics.practiceSections(duration: 60)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].name, "Verse 1")
        XCTAssertEqual(sections[0].end, 30, accuracy: 0.001)
        XCTAssertEqual(sections[1].end, 60, accuracy: 0.001)
    }

    /// A line repeated at several times is one text with several tags. Word
    /// timings are absolute, so only the first occurrence can carry them.
    func testRepeatedTimeTagsProduceSeveralLines() {
        let lyrics = LyricsFormat.parseLRC("[00:10.00][00:40.00]Chorus words here")
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[1].start ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Chorus words here", "Chorus words here"])
    }

    /// `[offset:]` runs the other way from ours: positive means *earlier*.
    func testOffsetTagIsInvertedAndRoundTrips() {
        let lyrics = LyricsFormat.parseLRC("[offset:500]\n[00:10.00]Line")
        XCTAssertEqual(lyrics.offset, -0.5, accuracy: 0.001)

        let written = LyricsFormat.lrcString(from: lyrics)
        XCTAssertTrue(written.contains("[offset:500]"), written)
        XCTAssertEqual(LyricsFormat.parseLRC(written).offset, -0.5, accuracy: 0.001)
    }

    func testRoundTripPreservesLinesAndWords() {
        let original = LyricsFormat.parseLRC("""
        [00:01.00][Intro]
        [00:05.50]<00:05.50>One <00:06.00>two
        [00:09.25]Plain line
        """)
        let reparsed = LyricsFormat.parseLRC(
            LyricsFormat.lrcString(from: original, title: "Song")
        )
        XCTAssertEqual(reparsed.lines.count, original.lines.count)
        XCTAssertEqual(reparsed.lines.map(\.text), original.lines.map(\.text))
        XCTAssertEqual(reparsed.lines.map(\.sectionLabel), original.lines.map(\.sectionLabel))
        for (left, right) in zip(reparsed.lines, original.lines) {
            XCTAssertEqual(left.start ?? -1, right.start ?? -1, accuracy: 0.01)
            XCTAssertEqual(left.words.map(\.text), right.words.map(\.text))
        }
    }

    func testUntimedFileParsesAsPlainLines() {
        let lyrics = LyricsFormat.parseLRC("First\nSecond\nThird")
        XCTAssertEqual(lyrics.lines.map(\.text), ["First", "Second", "Third"])
        XCTAssertTrue(lyrics.lines.allSatisfy { $0.start == nil })
    }

    // MARK: - Plain text

    func testPlainTextDropsBlankLinesAndKeepsSections() {
        let lines = LyricsFormat.parsePlainText("[Chorus]\n\nSing this\n   \nAnd this")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].sectionLabel, "Chorus")
        XCTAssertEqual(lines.map(\.text), ["", "Sing this", "And this"])
    }

    // MARK: - WebVTT

    func testParsesWebVTTCuesWithWordTimings() {
        let lines = LyricsFormat.parseWebVTT("""
        WEBVTT
        Kind: captions
        Language: en

        00:00:01.000 --> 00:00:03.000 align:start position:0%
        <00:00:01.100><c>Hello</c> <00:00:01.900><c>there</c>

        00:00:03.000 --> 00:00:05.000
        second line
        """)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "Hello there")
        XCTAssertEqual(lines[0].words.count, 2)
        XCTAssertEqual(lines[0].start ?? 0, 1.1, accuracy: 0.001)
        XCTAssertEqual(lines[0].end ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "second line")
    }

    /// Auto-generated captions roll: each cue repeats the one before it. Printed
    /// verbatim, every line of the song appears twice.
    func testRollingCaptionsAreDeduplicated() {
        let lines = LyricsFormat.parseWebVTT("""
        WEBVTT

        00:00:01.000 --> 00:00:03.000
        first part

        00:00:03.000 --> 00:00:05.000
        first part

        00:00:05.000 --> 00:00:07.000
        first part and more
        """)
        XCTAssertEqual(lines.map(\.text), ["first part", "and more"])
    }

    /// A real manual caption track: cues wrapped over two lines, and a first
    /// cue that is punctuation in brackets rather than a section name.
    func testWrappedCuesJoinAndMusicMarkersAreNotSections() {
        let lines = LyricsFormat.parseWebVTT("""
        WEBVTT
        Kind: captions
        Language: en

        00:00:01.360 --> 00:00:03.040
        [♪♪♪]

        00:00:22.640 --> 00:00:26.960
        ♪ You know the rules
        and so do I ♪

        00:00:30.000 --> 00:00:33.000
        [Chorus]
        """)
        XCTAssertEqual(lines.count, 3)
        XCTAssertNil(lines[0].sectionLabel, "a run of note glyphs names nothing")
        XCTAssertEqual(lines[1].text, "♪ You know the rules and so do I ♪")
        XCTAssertEqual(lines[2].sectionLabel, "Chorus")
    }

    func testTimestampParsingRejectsNonTimes() {
        XCTAssertNil(LyricsFormat.parseTimestamp("Chorus"))
        XCTAssertNil(LyricsFormat.parseTimestamp("ar:Somebody"))
        XCTAssertNil(LyricsFormat.parseTimestamp("00:99.00"))
        XCTAssertEqual(LyricsFormat.parseTimestamp("00:07") ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(LyricsFormat.parseTimestamp("01:02:03.500") ?? 0, 3723.5, accuracy: 0.001)
    }
}

final class SongLyricsTests: XCTestCase {
    private func makeLyrics() -> SongLyrics {
        SongLyrics(
            source: .manual,
            lines: [
                LyricLine(text: "one", start: 10),
                LyricLine(text: "two", start: 12),
                LyricLine(text: "three", start: 40),
            ]
        )
    }

    /// The playhead keeps the last line through a gap rather than showing
    /// nothing: the singer wants to see what they just sang and what is next.
    func testLineIndexHoldsThroughAGap() {
        let lyrics = makeLyrics()
        XCTAssertNil(lyrics.lineIndex(at: 5))
        XCTAssertEqual(lyrics.lineIndex(at: 10), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 11.9), 0)
        XCTAssertEqual(lyrics.lineIndex(at: 30), 1)
        XCTAssertEqual(lyrics.lineIndex(at: 400), 2)
    }

    func testOffsetShiftsEveryLine() {
        var lyrics = makeLyrics()
        lyrics.offset = 1
        XCTAssertNil(lyrics.lineIndex(at: 10.5))
        XCTAssertEqual(lyrics.lineIndex(at: 11), 0)
    }

    /// Only long instrumental stretches get a countdown; two lines of the same
    /// verse do not.
    func testVocalEntryCountdownOnlyForLongGaps() {
        let lyrics = makeLyrics()
        XCTAssertNil(lyrics.vocalEntryCountdown(at: 11), "two seconds is not a gap")
        let countdown = lyrics.vocalEntryCountdown(at: 37.5)
        XCTAssertEqual(countdown?.lineIndex, 2)
        XCTAssertEqual(countdown?.secondsRemaining ?? 0, 2.5, accuracy: 0.001)
        XCTAssertNil(lyrics.vocalEntryCountdown(at: 20), "too early to count in")
        XCTAssertNil(lyrics.vocalEntryCountdown(at: 45), "nothing left to count into")
    }

    /// The range a run of lines covers ends where the next line starts, and the
    /// last line runs to the end of the song.
    func testRangeAcrossLines() {
        let lyrics = makeLyrics()
        let first = lyrics.range(from: 0, to: 1, duration: 200)
        XCTAssertEqual(first?.start ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(first?.end ?? 0, 40, accuracy: 0.001)

        // Dragged upwards, the same two lines are the same range.
        let reversed = lyrics.range(from: 1, to: 0, duration: 200)
        XCTAssertEqual(reversed?.start ?? 0, first?.start ?? -1, accuracy: 0.001)

        let last = lyrics.range(from: 2, to: 2, duration: 200)
        XCTAssertEqual(last?.end ?? 0, 200, accuracy: 0.001)
    }

    func testWordProgressTracksTheSungWord() {
        let lyrics = SongLyrics(
            source: .manual,
            lines: [
                LyricLine(
                    text: "one two",
                    start: 10,
                    end: 12,
                    words: [
                        LyricWord(text: "one", start: 10),
                        LyricWord(text: "two", start: 11),
                    ]
                )
            ]
        )
        XCTAssertEqual(lyrics.wordProgress(inLineAt: 0, at: 10.5)?.index, 0)
        XCTAssertEqual(lyrics.wordProgress(inLineAt: 0, at: 10.5)?.fraction ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(lyrics.wordProgress(inLineAt: 0, at: 11.5)?.index, 1)
    }

    /// A file whose times run backwards costs one line, not the whole page.
    func testSanitizeClampsIntoTheSongAndKeepsOrder() {
        var lyrics = SongLyrics(
            source: .lrcFile,
            lines: [
                LyricLine(text: "one", start: 10),
                LyricLine(text: "two", start: 5),
                LyricLine(text: "three", start: 900),
                LyricLine(text: "untimed"),
            ],
            offset: 9
        )
        lyrics.sanitize(duration: 60)
        XCTAssertEqual(lyrics.offset, 2, "the global offset is a ±2 s nudge")
        XCTAssertEqual(lyrics.lines.map(\.text), ["one", "two", "three", "untimed"])
        XCTAssertEqual(lyrics.lines[1].start ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(lyrics.lines[2].start ?? 0, 60, accuracy: 0.001)
        XCTAssertNil(lyrics.lines[3].start)
    }

    /// "Labelled until edited", line by line.
    func testProvisionalUntilEveryLineIsEdited() {
        var lyrics = SongLyrics(
            source: .youtubeCaptions,
            lines: [LyricLine(text: "a", start: 1), LyricLine(text: "b", start: 2)]
        )
        XCTAssertTrue(lyrics.isProvisional)
        lyrics.edit(0) { $0.text = "A" }
        XCTAssertTrue(lyrics.isProvisional)
        lyrics.edit(1) { $0.text = "B" }
        XCTAssertFalse(lyrics.isProvisional)

        var typed = SongLyrics(source: .manual, lines: [LyricLine(text: "a")])
        XCTAssertFalse(typed.isProvisional, "the user's own words are never a guess")
        typed.edit(0) { $0.text = "b" }
        XCTAssertFalse(typed.isProvisional)
    }
}

final class LyricsStorageTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    func testLyricsRoundTripThroughSongStorage() throws {
        let storage = SongStorage(folderURL: library.folder(named: "Originals/\(UUID().uuidString)"))
        var lyrics = SongLyrics(source: .manual, lines: [LyricLine(text: "hello", start: 3)])
        lyrics.offset = -0.4
        try storage.write(lyrics, to: SongLyrics.filename)

        let read = try XCTUnwrap(storage.read(SongLyrics.self, from: SongLyrics.filename))
        XCTAssertEqual(read.lines.map(\.text), ["hello"])
        XCTAssertEqual(read.offset, -0.4, accuracy: 0.001)
        XCTAssertEqual(read.lines[0].id, lyrics.lines[0].id)
    }

    /// A damaged lyrics file must never make its song unopenable, and must
    /// never take the practice settings with it.
    func testDamagedLyricsAreAMissingResultNotAFailure() throws {
        let folder = library.folder(named: "Originals/\(UUID().uuidString)")
        let storage = SongStorage(folderURL: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"source":"manual","lines":[{"te"#.utf8)
            .write(to: storage.url(for: SongLyrics.filename))

        var settings = SongPracticeSettings()
        settings.loopStart = 5
        settings.loopEnd = 15
        PracticeSettingsStore().save(settings, to: storage)

        XCTAssertNil(storage.read(SongLyrics.self, from: SongLyrics.filename))
        XCTAssertEqual(PracticeSettingsStore().load(from: storage).loopStart, 5)
    }

    /// Lyrics are counted as the song's own data, so Phase 10's storage screen
    /// reports them rather than folding them into the audio.
    func testLyricsCountTowardsSongData() throws {
        let folder = library.folder(named: "Originals/\(UUID().uuidString)")
        let storage = SongStorage(folderURL: folder)
        try storage.write(
            SongLyrics(source: .manual, lines: [LyricLine(text: "hello", start: 1)]),
            to: SongLyrics.filename
        )
        XCTAssertGreaterThan(SongStorage.songDataByteCount(of: folder), 0)
    }
}
