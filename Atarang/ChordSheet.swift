import Foundation

/// One chord symbol, and where in a line of words it belongs.
struct SheetChord: Equatable, Sendable, Identifiable {
    /// The chord segment this came from, so a correction made from the sheet
    /// finds its way back to the right chord.
    let id: UUID
    let symbol: String
    let spokenName: String
    let time: TimeInterval
    /// The character of the line's text the symbol sits over.
    let characterIndex: Int
    /// True when a word timing put it there, false when it was interpolated
    /// across the line. The sheet says which, because a symbol printed over the
    /// wrong syllable is worse than one the reader knows is approximate.
    let isExact: Bool
    let isSimplified: Bool
}

/// One line of the sheet: the words, and the chords over them.
struct SheetLine: Equatable, Sendable, Identifiable {
    let id: UUID
    /// Index into the lyrics, so tapping the line can seek to it.
    let index: Int
    let text: String
    let sectionLabel: String?
    let start: TimeInterval?
    /// Chords played in the instrumental stretch before this line, which no
    /// word can carry. Printed on their own row above it rather than dropped —
    /// an intro is usually the part somebody needs the chart for most.
    var leadingChords: [SheetChord] = []
    var chords: [SheetChord] = []

    var isSection: Bool { sectionLabel != nil }

    /// The words split at the chord positions: one chunk per chord, plus
    /// whatever comes before the first one.
    var chunks: [Chunk] {
        struct Boundary { let index: Int; let chord: SheetChord? }
        let characters = Array(text)
        var boundaries: [Boundary] = []
        if chords.first?.characterIndex != 0 {
            boundaries.append(Boundary(index: 0, chord: nil))
        }
        for chord in chords {
            boundaries.append(
                Boundary(index: min(max(0, chord.characterIndex), characters.count), chord: chord)
            )
        }
        return boundaries.enumerated().map { position, boundary in
            let end = position + 1 < boundaries.count
                ? boundaries[position + 1].index
                : characters.count
            let text = boundary.index < end
                ? String(characters[boundary.index..<max(boundary.index, end)])
                : ""
            return Chunk(id: boundary.chord?.id ?? id, chord: boundary.chord, text: text)
        }
    }

    struct Chunk: Identifiable, Equatable, Sendable {
        let id: UUID
        let chord: SheetChord?
        let text: String
    }
}

/// The words and the harmony, laid out together.
///
/// Built fresh whenever either changes rather than stored: it is a view of two
/// artifacts that each have their own file, and a third copy would be a third
/// thing to keep in step.
struct ChordSheet: Equatable, Sendable {
    var lines: [SheetLine] = []
    /// True when at least one chord was placed by a word timing rather than by
    /// interpolation.
    var hasExactPlacements = false
    /// True when at least one chord had to be interpolated across a line.
    ///
    /// The badge is driven by this rather than by the absence of exact
    /// placements: a page can be entirely correct and still contain no chord
    /// that a word timing had to decide, and saying "estimated" about that page
    /// would be a warning about nothing.
    var hasEstimatedPlacements = false
    /// True when the lyrics carry no times at all, so nothing could be placed.
    var needsTiming = false

    var isEmpty: Bool { lines.allSatisfy { $0.chords.isEmpty && $0.leadingChords.isEmpty } }

    static func build(
        lyrics: SongLyrics,
        chords: SongChords,
        duration: TimeInterval
    ) -> ChordSheet {
        var sheet = ChordSheet()
        let prefersFlats = chords.prefersFlats
        guard !lyrics.lines.isEmpty else { return sheet }
        sheet.needsTiming = lyrics.timedLineCount == 0

        // Where each line runs to: the next timed line, or the song's end. A
        // line's own `end` is used when the source gave one, because a cue that
        // says where it stops is better evidence than the next cue's start.
        func lineEnd(after index: Int) -> TimeInterval {
            if let end = lyrics.lines[index].end.map({ $0 + lyrics.offset }) { return end }
            if let next = lyrics.nextTimedIndex(after: index),
               let start = lyrics.effectiveStart(atIndex: next) {
                return start
            }
            return duration
        }

        var consumed = Set<UUID>()
        var lineStarts: [(index: Int, start: TimeInterval)] = []
        for index in lyrics.lines.indices {
            guard let start = lyrics.effectiveStart(atIndex: index) else { continue }
            lineStarts.append((index, start))
        }

        var built: [SheetLine] = lyrics.lines.enumerated().map { index, line in
            SheetLine(
                id: line.id,
                index: index,
                text: line.text,
                sectionLabel: line.sectionLabel,
                start: lyrics.effectiveStart(atIndex: index)
            )
        }

        for (index, start) in lineStarts {
            let line = lyrics.lines[index]
            let end = max(start, lineEnd(after: index))
            var placed: [SheetChord] = []

            // The chord already sounding when the line begins belongs over its
            // first word: a singer coming in mid-chord still has to know what
            // is under them.
            if let sounding = chords.segment(at: start), sounding.chord != nil,
               !consumed.contains(sounding.id) {
                placed.append(
                    sheetChord(
                        from: sounding,
                        at: 0,
                        isExact: true,
                        prefersFlats: prefersFlats
                    )
                )
                consumed.insert(sounding.id)
            }

            for segment in chords.segments
            where segment.chord != nil
                && segment.start >= start
                && segment.start < end
                && !consumed.contains(segment.id) {
                let placement = position(
                    of: segment.start,
                    in: line,
                    lineStart: start,
                    lineEnd: end,
                    offset: lyrics.offset
                )
                if placement.isExact {
                    sheet.hasExactPlacements = true
                } else {
                    sheet.hasEstimatedPlacements = true
                }
                placed.append(
                    sheetChord(
                        from: segment,
                        at: placement.characterIndex,
                        isExact: placement.isExact,
                        prefersFlats: prefersFlats
                    )
                )
                consumed.insert(segment.id)
            }

            built[index].chords = placed
                .sorted { $0.characterIndex == $1.characterIndex ? $0.time < $1.time : $0.characterIndex < $1.characterIndex }
        }

        // Anything left over was played where nobody was singing. It goes above
        // the next line that starts after it, or on the last line when the song
        // plays out past the words.
        for segment in chords.segments where segment.chord != nil && !consumed.contains(segment.id) {
            let target = lineStarts.first { $0.start > segment.start }?.index
                ?? lineStarts.last?.index
            guard let target else { continue }
            built[target].leadingChords.append(
                sheetChord(from: segment, at: 0, isExact: true, prefersFlats: prefersFlats)
            )
        }
        for index in built.indices {
            built[index].leadingChords.sort { $0.time < $1.time }
        }

        sheet.lines = built
        return sheet
    }

    private static func sheetChord(
        from segment: ChordSegment,
        at characterIndex: Int,
        isExact: Bool,
        prefersFlats: Bool
    ) -> SheetChord {
        SheetChord(
            id: segment.id,
            symbol: segment.symbol(preferringFlats: prefersFlats),
            spokenName: segment.chord?.spokenName(preferringFlats: prefersFlats) ?? "no chord",
            time: segment.start,
            characterIndex: characterIndex,
            isExact: isExact,
            isSimplified: segment.isSimplified
        )
    }

    /// Which character a chord lands on.
    ///
    /// Exact when the line has word timings — the chord goes over the word being
    /// sung when it changes, which is what a printed songbook does. Otherwise it
    /// is interpolated across the line and pulled back to the start of the word
    /// it lands in, because a symbol printed over the middle of a word is a
    /// symbol nobody can read.
    static func position(
        of time: TimeInterval,
        in line: LyricLine,
        lineStart: TimeInterval,
        lineEnd: TimeInterval,
        offset: TimeInterval = 0
    ) -> (characterIndex: Int, isExact: Bool) {
        let characters = Array(line.text)
        guard !characters.isEmpty else { return (0, false) }

        if !line.words.isEmpty {
            var cursor = 0
            var best: Int?
            for word in line.words {
                guard let range = wordRange(word.text, in: characters, from: cursor) else { continue }
                cursor = range.upperBound
                if word.start + offset <= time + 0.001 {
                    best = range.lowerBound
                } else {
                    break
                }
            }
            if let best { return (best, true) }
            // Before the first word is the start of the line, and that is an
            // exact answer rather than a failed one.
            return (0, true)
        }

        let span = max(0.001, lineEnd - lineStart)
        let fraction = min(1, max(0, (time - lineStart) / span))
        let raw = Int((Double(characters.count) * fraction).rounded())
        return (wordStart(atOrBefore: min(raw, characters.count - 1), in: characters), false)
    }

    private static func wordRange(
        _ word: String,
        in characters: [Character],
        from cursor: Int
    ) -> Range<Int>? {
        let needle = Array(word.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty, cursor <= characters.count else { return nil }
        var index = cursor
        while index + needle.count <= characters.count {
            if Array(characters[index..<index + needle.count]) == needle {
                return index..<(index + needle.count)
            }
            index += 1
        }
        return nil
    }

    /// The first character of the word containing `index`.
    private static func wordStart(atOrBefore index: Int, in characters: [Character]) -> Int {
        var position = min(max(0, index), characters.count - 1)
        while position > 0, !characters[position - 1].isWhitespace {
            position -= 1
        }
        return position
    }
}
