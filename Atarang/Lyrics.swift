import Foundation

/// One word of a lyric line, with the moment it is sung.
///
/// Word timings are optional throughout: an `.lrc` file with only line tags,
/// or a set of lines the user typed and timestamped by tapping, has none. Every
/// display that uses them degrades to line granularity when they are absent.
struct LyricWord: Codable, Equatable, Sendable {
    var text: String
    /// Source-song seconds, like every other timestamp in the app, so it stays
    /// correct under speed and pitch changes.
    var start: TimeInterval
}

/// Where a set of lyrics came from.
///
/// This is not bookkeeping: it decides whether the app is allowed to present
/// the words as fact. Anything the user did not write or correct themselves is
/// labelled until they do.
enum LyricsSource: String, Codable, Sendable, CaseIterable {
    /// Typed or pasted by the user, and timed by them.
    case manual
    case lrcFile
    case youtubeCaptions
    case lrclib
    /// Reserved for Milestone E. Nothing produces it yet.
    case transcription

    var label: String {
        switch self {
        case .manual: "Typed here"
        case .lrcFile: "Imported .lrc"
        case .youtubeCaptions: "YouTube captions"
        case .lrclib: "LRCLIB"
        case .transcription: "Transcribed"
        }
    }

    /// True when the words are the app's guess rather than the user's own, so
    /// they must be visibly labelled until edited.
    var isProvisional: Bool { self != .manual }

    /// Said plainly, once, rather than implied by a colour.
    var confidenceNote: String? {
        switch self {
        case .manual: nil
        case .lrcFile: "Imported from a file. Times are whatever the file said."
        case .youtubeCaptions:
            "Automatic captions. Wording and timing are often approximate — correct anything that is wrong."
        case .lrclib: "Contributed to LRCLIB by someone else. Check the timing against your version."
        case .transcription: "Transcribed on this device. Treat every line as a guess."
        }
    }
}

/// One line of a song: what is sung, and when.
///
/// A line with no `start` is not broken — it is lyrics waiting to be timed,
/// which is exactly what pasting plain words produces and what tap-to-timestamp
/// then fills in.
struct LyricLine: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var start: TimeInterval?
    /// Known only where the source says so — WebVTT cues carry it, `.lrc` line
    /// tags do not.
    var end: TimeInterval?
    var words: [LyricWord] = []
    /// Set by any hand edit to the line's text or timing. Re-analysis must
    /// never overwrite a line the user has corrected.
    var isUserEdited = false
    /// Non-nil when the line *is* a structural marker — `[Chorus]`, `[Verse 2]`
    /// — rather than something sung.
    var sectionLabel: String?

    var isSection: Bool { sectionLabel != nil }

    init(
        id: UUID = UUID(),
        text: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        words: [LyricWord] = [],
        isUserEdited: Bool = false,
        sectionLabel: String? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.words = words
        self.isUserEdited = isUserEdited
        self.sectionLabel = sectionLabel
    }

    /// What to show: the label for a section marker, the words otherwise.
    var displayText: String { sectionLabel ?? text }
}

/// Everything the app knows about a song's words.
///
/// It conforms to `AnalysisArtifact` for its filename and version, but it is
/// deliberately read *without* the version gate `readAnalysis` applies. A chord
/// grid at a version we no longer produce is stale output and worth discarding;
/// lyrics are half the user's own work — words they typed, times they tapped,
/// corrections they made — and no algorithm change can make those wrong.
struct SongLyrics: AnalysisArtifact, Equatable {
    static let currentAnalysisVersion = 1
    static var filename: String { SongStorage.lyricsFilename }

    /// How close to the next line the countdown starts, and the shortest gap
    /// worth counting into. Four seconds is long enough that the singer has
    /// stopped counting bars and short enough that a number on screen is still
    /// about *this* entry.
    static let vocalEntryGap: TimeInterval = 4

    var analysisVersion = Self.currentAnalysisVersion
    var source: LyricsSource
    /// Seconds added to every line time when displaying. Positive means the
    /// words arrive later. This is the global nudge, kept separate from the
    /// line times so it stays reversible and so `.lrc` export can express it.
    var offset: TimeInterval = 0
    var lines: [LyricLine] = []
    var updatedAt = Date()
    /// What the source called this song, when it can say — an LRCLIB match's
    /// track and artist, for instance. Shown so a wrong match is recognisable.
    var attribution: String?

    init(
        source: LyricsSource,
        lines: [LyricLine] = [],
        offset: TimeInterval = 0,
        attribution: String? = nil
    ) {
        self.source = source
        self.lines = lines
        self.offset = offset
        self.attribution = attribution
    }

    // MARK: - Shape

    var isEmpty: Bool { lines.isEmpty }
    var timedLineCount: Int { lines.filter { $0.start != nil }.count }
    var hasWordTimings: Bool { lines.contains { !$0.words.isEmpty } }

    /// True while any line is still the app's guess. Clears line by line as the
    /// user corrects them, which is what "labelled until edited" means.
    var isProvisional: Bool {
        source.isProvisional && lines.contains { !$0.isUserEdited }
    }

    var sungLines: [LyricLine] { lines.filter { !$0.isSection } }

    // MARK: - Lookup

    func effectiveStart(of line: LyricLine) -> TimeInterval? {
        line.start.map { max(0, $0 + offset) }
    }

    func effectiveStart(atIndex index: Int) -> TimeInterval? {
        guard lines.indices.contains(index) else { return nil }
        return effectiveStart(of: lines[index])
    }

    /// The line the playhead is inside, meaning the last one that has started.
    ///
    /// It deliberately keeps returning the previous line through an
    /// instrumental gap: the singer wants to see what they just sang and what
    /// is coming, not an empty screen for sixteen bars.
    func lineIndex(at time: TimeInterval) -> Int? {
        var result: Int?
        for (index, line) in lines.enumerated() {
            guard let start = effectiveStart(of: line) else { continue }
            if start <= time { result = index } else { break }
        }
        return result
    }

    /// The next line with a time after `index`, in document order.
    func nextTimedIndex(after index: Int?) -> Int? {
        let start = index.map { $0 + 1 } ?? 0
        guard start < lines.count else { return nil }
        return lines[start...].firstIndex { $0.start != nil }
    }

    /// How long the instrumental stretch before a line lasts, measured from the
    /// end of the line before it — or, when the source gave no end, from where
    /// that line began.
    func gapBefore(_ index: Int) -> TimeInterval? {
        guard let start = effectiveStart(atIndex: index) else { return nil }
        let previous = lines[..<index].last { $0.start != nil }
        guard let previous else { return start }
        let previousEnd = previous.end.map { $0 + offset } ?? (previous.start! + offset)
        return max(0, start - previousEnd)
    }

    /// The countdown to the next vocal entry, or `nil` when there is nothing
    /// worth counting into.
    ///
    /// Only long gaps qualify. Counting the singer in between two lines of the
    /// same verse would be noise on screen at the exact moment they are reading
    /// it.
    func vocalEntryCountdown(at time: TimeInterval) -> (secondsRemaining: TimeInterval, lineIndex: Int)? {
        guard let next = nextTimedIndex(after: lineIndex(at: time)),
              let start = effectiveStart(atIndex: next),
              let gap = gapBefore(next),
              gap > Self.vocalEntryGap else { return nil }
        let remaining = start - time
        guard remaining > 0, remaining <= Self.vocalEntryGap else { return nil }
        return (remaining, next)
    }

    /// Which word of a line is being sung, and how far through it the playhead
    /// is. `nil` when the line has no word timings.
    func wordProgress(inLineAt index: Int, at time: TimeInterval) -> (index: Int, fraction: Double)? {
        guard lines.indices.contains(index) else { return nil }
        let line = lines[index]
        guard !line.words.isEmpty else { return nil }
        let starts = line.words.map { $0.start + offset }
        guard let current = starts.lastIndex(where: { $0 <= time }) else {
            return (0, 0)
        }
        let wordStart = starts[current]
        let wordEnd = current + 1 < starts.count
            ? starts[current + 1]
            : (line.end.map { $0 + offset } ?? wordStart + 0.6)
        let span = max(0.05, wordEnd - wordStart)
        return (current, min(1, max(0, (time - wordStart) / span)))
    }

    /// The A–B range a run of lines covers, ending where the next line starts
    /// or, for the last line, at the end of the song.
    func range(from lower: Int, to upper: Int, duration: TimeInterval) -> (start: TimeInterval, end: TimeInterval)? {
        let first = min(lower, upper)
        let last = max(lower, upper)
        guard let start = effectiveStart(atIndex: first) else { return nil }
        let end: TimeInterval
        if let next = nextTimedIndex(after: last), let nextStart = effectiveStart(atIndex: next) {
            end = nextStart
        } else {
            end = duration
        }
        guard end > start else { return nil }
        return (start, min(end, duration))
    }

    // MARK: - Sections

    /// The saved practice sections these lyrics describe.
    ///
    /// A section runs from its label to the next one, which is the only reading
    /// of `[Chorus]` that produces a range rather than a point. Labels with no
    /// time cannot become sections and are skipped.
    func practiceSections(duration: TimeInterval) -> [SavedPracticeSection] {
        let labelled = lines.indices.filter { lines[$0].isSection && lines[$0].start != nil }
        return labelled.enumerated().compactMap { position, index in
            guard let start = effectiveStart(atIndex: index) else { return nil }
            let nextLabel = position + 1 < labelled.count ? labelled[position + 1] : nil
            let end = nextLabel.flatMap { effectiveStart(atIndex: $0) } ?? duration
            guard end - start >= PlaybackLoopRange.minimumDuration else { return nil }
            return SavedPracticeSection(
                name: lines[index].sectionLabel ?? "Section",
                start: start,
                end: min(end, duration)
            )
        }
    }

    // MARK: - Editing

    /// Clamps everything into the song and keeps timed lines in order.
    ///
    /// Lines are *not* re-sorted. Document order is what the user reads and
    /// what tap-to-timestamp walks down; a file whose times run backwards is
    /// repaired by clamping each line to the one before it, so a single bad
    /// timestamp costs one line rather than scrambling the page.
    mutating func sanitize(duration: TimeInterval) {
        offset = offset.isFinite ? min(max(offset, -2), 2) : 0
        var previous: TimeInterval = 0
        for index in lines.indices {
            lines[index].text = lines[index].text.trimmingCharacters(in: .whitespaces)
            guard let start = lines[index].start else {
                lines[index].words = []
                continue
            }
            guard start.isFinite else {
                lines[index].start = nil
                lines[index].words = []
                continue
            }
            let clamped = min(max(previous, max(0, start)), max(0, duration))
            lines[index].start = clamped
            previous = clamped
            if let end = lines[index].end {
                lines[index].end = min(max(clamped, end), max(0, duration))
            }
            lines[index].words = lines[index].words
                .filter { $0.start.isFinite }
                .map { word in
                    var word = word
                    word.start = min(max(clamped, word.start), max(0, duration))
                    return word
                }
        }
        lines.removeAll { $0.text.isEmpty && $0.sectionLabel == nil }
    }

    /// Applies a hand edit and records that it was one.
    mutating func edit(_ index: Int, _ body: (inout LyricLine) -> Void) {
        guard lines.indices.contains(index) else { return }
        body(&lines[index])
        lines[index].isUserEdited = true
        updatedAt = Date()
    }
}
