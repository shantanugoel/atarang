import Foundation

/// Reading and writing the three text shapes lyrics arrive in.
///
/// All three are parsed by hand rather than by regular expression. The formats
/// are small, the inputs are hostile — an auto-generated caption file is not
/// written for a parser's benefit — and a hand-written scanner can say "this
/// bracket is not a timestamp, so the rest of the line is words" without
/// backtracking.
enum LyricsFormat {
    // MARK: - LRC

    /// Parses an `.lrc` file.
    ///
    /// Handles `[mm:ss.xx]` line tags including several on one line, `<mm:ss.xx>`
    /// word tags, and the `[offset:]`, `[ti:]`, `[ar:]` metadata tags. Anything
    /// bracketed that is neither a timestamp nor a `key:value` pair is treated as
    /// text, which is what makes `[Chorus]` a section label rather than a parse
    /// error.
    static func parseLRC(_ text: String, source: LyricsSource = .lrcFile) -> SongLyrics {
        var lyrics = SongLyrics(source: source)
        var fileOffsetSeconds: TimeInterval = 0
        var title: String?
        var artist: String?
        var parsed: [(order: Int, line: LyricLine)] = []
        var order = 0
        var sawTimestamp = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = Substring(rawLine).trimmingCharacters(in: .whitespaces)[...]
            var starts: [TimeInterval] = []

            // Consume leading bracketed tags. The first bracket that is neither
            // a time nor metadata ends the header and belongs to the text.
            while remainder.hasPrefix("["), let close = remainder.firstIndex(of: "]") {
                let body = String(remainder[remainder.index(after: remainder.startIndex)..<close])
                if let seconds = parseTimestamp(body) {
                    starts.append(seconds)
                } else if let colon = body.firstIndex(of: ":") {
                    let key = body[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "offset": fileOffsetSeconds = (Double(value) ?? 0) / 1000
                    case "ti": title = value
                    case "ar": artist = value
                    default: break
                    }
                } else {
                    break
                }
                remainder = remainder[remainder.index(after: close)...]
            }

            let body = String(remainder).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty || !starts.isEmpty else { continue }
            if !starts.isEmpty { sawTimestamp = true }
            let content = parseWordTags(body)
            let label = sectionLabel(in: content.text)

            if starts.isEmpty {
                parsed.append((order, LyricLine(
                    text: label == nil ? content.text : "",
                    words: content.words,
                    sectionLabel: label
                )))
                order += 1
            } else {
                // One text, several times, is how `.lrc` says "this line
                // repeats". Word tags are absolute, so they can only belong to
                // one of those occurrences; the repeats keep the words and lose
                // the sweep rather than sweeping at the wrong moment.
                for (position, start) in starts.enumerated() {
                    parsed.append((order, LyricLine(
                        text: label == nil ? content.text : "",
                        start: start,
                        words: position == 0 ? content.words : [],
                        sectionLabel: label
                    )))
                    order += 1
                }
            }
        }

        // Only reorder when the file actually carries times; a plain-text file
        // read through this path keeps the order it was written in.
        if sawTimestamp {
            parsed.sort { left, right in
                switch (left.line.start, right.line.start) {
                case let (l?, r?): return l == r ? left.order < right.order : l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return left.order < right.order
                }
            }
        }
        lyrics.lines = parsed.map(\.line)
        // `[offset:]` is defined the other way round from ours: a positive value
        // makes the words appear *earlier*. Flipping it here means the slider in
        // the app and the tag in the file both keep their own conventions.
        lyrics.offset = min(max(-fileOffsetSeconds, -2), 2)
        if let title {
            lyrics.attribution = [title, artist].compactMap { $0 }.joined(separator: " — ")
        }
        return lyrics
    }

    /// Serialises back to `.lrc`, with word tags where they exist.
    static func lrcString(from lyrics: SongLyrics, title: String? = nil) -> String {
        var out: [String] = []
        if let title, !title.isEmpty { out.append("[ti:\(title)]") }
        out.append("[re:Atarang]")
        if abs(lyrics.offset) > 0.0005 {
            out.append("[offset:\(Int((-lyrics.offset * 1000).rounded()))]")
        }
        for line in lyrics.lines {
            let text = line.sectionLabel.map { "[\($0)]" } ?? line.text
            guard let start = line.start else {
                if !text.isEmpty { out.append(text) }
                continue
            }
            if line.words.isEmpty {
                out.append("[\(timestamp(start))]\(text)")
            } else {
                let body = line.words
                    .map { "<\(timestamp($0.start))>\($0.text)" }
                    .joined(separator: " ")
                out.append("[\(timestamp(start))]\(body)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Plain text

    /// Turns pasted words into untimed lines.
    ///
    /// Blank lines are dropped rather than kept as spacers: they carry no time,
    /// and a reading view that scrolls a blank line into the large centre slot
    /// is showing the singer nothing at the moment they most need something.
    static func parsePlainText(_ text: String) -> [LyricLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let label = sectionLabel(in: line)
                return LyricLine(text: label == nil ? line : "", sectionLabel: label)
            }
    }

    // MARK: - WebVTT

    /// Parses WebVTT cues, as produced by YouTube's caption tracks.
    ///
    /// Auto-generated captions roll: each cue repeats the tail of the one
    /// before it so the words appear to scroll. Emitting them verbatim would
    /// produce a page where every line is printed two or three times, so a cue
    /// that merely extends its predecessor contributes only what it adds.
    static func parseWebVTT(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        var block: [String] = []

        func flush() {
            defer { block = [] }
            // A block with no timing arrow is the file header or a stray note,
            // not a cue.
            guard let headerIndex = block.firstIndex(where: { $0.contains("-->") }) else { return }
            let times = block[headerIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = parseTimestamp(times[0].trimmingCharacters(in: .whitespaces)) else { return }
            let end = parseTimestamp(
                times[1].trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
            )
            let payload = block[(headerIndex + 1)...].joined(separator: " ")
            let content = parseWordTags(stripMarkup(payload))
            var cleaned = content.text.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return }

            if let previous = lines.last?.text {
                if cleaned == previous { return }
                if cleaned.hasPrefix(previous) {
                    cleaned = String(cleaned.dropFirst(previous.count))
                        .trimmingCharacters(in: .whitespaces)
                    guard !cleaned.isEmpty else { return }
                }
            }
            let label = sectionLabel(in: cleaned)
            lines.append(
                LyricLine(
                    text: label == nil ? cleaned : "",
                    start: content.words.first?.start ?? start,
                    end: end,
                    words: content.words,
                    sectionLabel: label
                )
            )
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else {
                block.append(line)
            }
        }
        flush()
        return lines
    }

    // MARK: - Shared scanning

    /// `mm:ss`, `mm:ss.xx` — the `.lrc` line and word tag — and `hh:mm:ss.xxx`,
    /// which is what WebVTT writes. Returns `nil` for anything else, which is
    /// how the LRC scanner tells a timestamp from a section label.
    static func parseTimestamp(_ value: String) -> TimeInterval? {
        var parts = value.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var hours = 0.0
        if parts.count == 3 {
            guard let value = Double(parts[0]), value >= 0 else { return nil }
            hours = value
            parts.removeFirst()
        }
        guard let minutes = Double(parts[0]),
              let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              minutes >= 0, seconds >= 0, seconds < 60 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// `mm:ss.xx`, the form `.lrc` line and word tags use.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let value = max(0, seconds)
        let minutes = Int(value) / 60
        let remainder = value - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remainder)
    }

    /// Pulls `<mm:ss.xx>` word tags out of a line, returning the plain text and
    /// the words that carried times.
    private static func parseWordTags(_ text: String) -> (text: String, words: [LyricWord]) {
        guard text.contains("<") else { return (text, []) }
        var words: [LyricWord] = []
        var plain = ""
        var index = text.startIndex
        var pendingStart: TimeInterval?

        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let body = String(text[text.index(after: index)..<close])
                if let seconds = parseTimestamp(body) {
                    pendingStart = seconds
                }
                index = text.index(after: close)
                continue
            }
            let next = text[index...].firstIndex(of: "<") ?? text.endIndex
            let chunk = String(text[index..<next])
            plain += chunk
            let word = chunk.trimmingCharacters(in: .whitespaces)
            if let start = pendingStart, !word.isEmpty {
                words.append(LyricWord(text: word, start: start))
                pendingStart = nil
            }
            index = next
        }
        // Stripped markup leaves runs of spaces where the tags used to be.
        return (plain.split(separator: " ").joined(separator: " "), words)
    }

    /// Removes the `<c>`, `<i>`, and `<v Speaker>` markup captions carry, while
    /// leaving `<mm:ss.xxx>` tags for the word scanner.
    private static func stripMarkup(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "<", let close = text[index...].firstIndex(of: ">") else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<close])
            if parseTimestamp(body) != nil {
                out += "<\(body)>"
            }
            index = text.index(after: close)
        }
        return out.replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// `[Chorus]` and `(Verse 2)` are structure, not singing. Anything longer
    /// than a few words inside brackets is treated as a lyric — bracketed
    /// backing vocals are common and are not section markers.
    private static func sectionLabel(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.count <= 40 else { return nil }
        let opens: [Character] = ["[", "("]
        let closes: [Character] = ["]", ")"]
        guard let first = trimmed.first, let last = trimmed.last,
              let openIndex = opens.firstIndex(of: first),
              closes.firstIndex(of: last) == openIndex else { return nil }
        let body = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty, !body.contains(first), body.split(separator: " ").count <= 3,
              // A caption track's very first cue is routinely `[♪♪♪]` or
              // `[MUSIC]`; the second of those is a section name and the first
              // is punctuation. A label has to be able to name something.
              body.rangeOfCharacter(from: .alphanumerics) != nil else {
            return nil
        }
        return body
    }
}
