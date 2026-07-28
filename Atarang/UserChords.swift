import Foundation

enum UserChordOrigin: String, Codable, Sendable {
    case pasted
    case chordProFile

    var label: String {
        switch self {
        case .pasted: "Pasted chart"
        case .chordProFile: "Imported ChordPro"
        }
    }
}

enum ChordChartSelection: Codable, Hashable, Sendable {
    case detected
    case user(UUID)
}

struct ImportedChordMetadata: Codable, Equatable, Sendable {
    var title: String?
    var artist: String?
    var key: MusicalKey?
    var sourceCapo = 0
    var tempo: Double?
    var duration: TimeInterval?
    var beatsPerBar: Int?
    var beatUnit: Int?
}

struct ImportedChordWarning: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case unknownDirective
        case unknownChord
        case ignoredTab
        case estimatedPlacement
        case arrangementMismatch
        case audioDisagreement
        case malformedMetadata
        case pitchMismatch
    }

    var id = UUID()
    var kind: Kind
    var message: String
    var line: Int?
}

struct ImportedChordSection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var firstEventIndex: Int
}

struct ImportedLyricAnchor: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var lineIndex: Int
    var text: String
    var section: String?
}

enum ImportedChordLocation: Codable, Equatable, Sendable {
    case lyric(line: Int, character: Int)
    case grid(bar: Int, beat: Double)
    case ordinal(Int)
    case unresolved
}

struct ImportedChordEvent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// `nil` is an explicit N.C., never a parse failure.
    var chord: Chord?
    var printedSymbol: String
    var location: ImportedChordLocation
    var parseConfidence: Double
    var section: String?
}

struct ImportedChordDocument: Codable, Equatable, Sendable {
    static let currentParseVersion = 1

    var parseVersion = Self.currentParseVersion
    var originalText: String
    var metadata = ImportedChordMetadata()
    var sections: [ImportedChordSection] = []
    var lyricAnchors: [ImportedLyricAnchor] = []
    var events: [ImportedChordEvent] = []
    var warnings: [ImportedChordWarning] = []

    var chordCount: Int { events.filter { $0.chord != nil }.count }
}

struct ChordChartAlignment: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = Self.currentVersion
    var parseCoverage: Double
    var lyricAnchorCoverage: Double
    var beatCoverage: Double
    var audioAgreement: Double?
    var confidence: Double
    var usedEstimatedPlacements: Bool
    var likelyArrangementMismatch: Bool
    var warnings: [ImportedChordWarning]
    var alignedAt = Date()
    /// How far the chart was moved to match this recording's pitch, in
    /// semitones. Zero means it is stored exactly as written.
    ///
    /// Optional so charts imported before this existed still decode: this file
    /// is user data and is never discarded for being old.
    var appliedPitchOffset: Int?
    /// What the recording suggests it should be, when that differs.
    var suggestedPitchOffset: Int?
    /// How much of the song the chart and the local analysis name the same
    /// root, at the offset currently applied.
    var pitchAgreement: Double?

    var pitchOffset: Int { appliedPitchOffset ?? 0 }

    /// True when the recording appears to be in a different key from the chart
    /// — a capo, a tuned-down guitar, or simply another version.
    var suggestsDifferentPitch: Bool {
        guard let suggestedPitchOffset else { return false }
        return suggestedPitchOffset != pitchOffset
    }

    var statusLabel: String {
        if suggestsDifferentPitch { return "different pitch from this recording" }
        if likelyArrangementMismatch { return "possible different arrangement" }
        if usedEstimatedPlacements { return "some positions estimated" }
        return "aligned"
    }
}

struct UserChordChart: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var origin: UserChordOrigin
    var importedAt = Date()
    var updatedAt = Date()
    var sourceMetadata: ImportedChordMetadata
    var document: ImportedChordDocument
    var alignment: ChordChartAlignment?
    var chords: SongChords?
}

struct UserChordCollection: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let filename = "user-chords.json"

    var schemaVersion = Self.currentSchemaVersion
    var selectedSource: ChordChartSelection = .detected
    var charts: [UserChordChart] = []
}

// MARK: - Chord symbols

enum ChordSymbolParser {
    enum Result: Equatable {
        case chord(Chord)
        case noChord
    }

    /// Reads one chord symbol.
    ///
    /// `allowsDegrees` exists because Nashville and Roman numerals are only
    /// safe where the author declared "this is a chord" — inside ChordPro
    /// brackets or a grid cell. In bare pasted text they turn ordinary words
    /// into chords: with a key set, the "I" of a sung line parses as the tonic.
    static func parse(
        _ source: String,
        key: MusicalKey? = nil,
        sourceCapo: Int = 0,
        allowsDegrees: Bool = true
    ) -> Result? {
        var token = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
            .replacingOccurrences(of: "＃", with: "#")
        while token.hasPrefix("(") && token.hasSuffix(")") {
            token = String(token.dropFirst().dropLast())
        }
        let upper = token.uppercased()
        if ["N.C.", "N.C", "NC", "NOCHORD", "NOCHORD."].contains(upper) { return .noChord }

        if allowsDegrees, let degree = degreeRoot(token, key: key) {
            return makeChord(
                root: degree.root,
                token: degree.remainder,
                isMinorByDefault: degree.isMinorByDefault,
                sourceCapo: sourceCapo
            )
        }
        guard let root = notePrefix(token) else { return nil }
        token.removeFirst(root.length)
        return makeChord(
            root: root.pitch,
            token: token,
            isMinorByDefault: false,
            sourceCapo: sourceCapo
        )
    }

    private static func makeChord(
        root: Int,
        token: String,
        isMinorByDefault: Bool,
        sourceCapo: Int
    ) -> Result? {
        let pieces = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var suffix = pieces.first.map(String.init) ?? ""
        // A lowercase Roman numeral carries the third: `vi` is minor, and so is
        // `vi7`. Reading the suffix without it turned every extended lowercase
        // degree into a dominant chord — a different chord, silently.
        if isMinorByDefault, !startsWithExplicitThird(suffix) {
            suffix = "m" + suffix
        }
        guard let quality = quality(for: suffix) else { return nil }
        var bass: Int?
        if pieces.count == 2 {
            guard let parsedBass = notePrefix(String(pieces[1])),
                  parsedBass.length == pieces[1].count else { return nil }
            bass = parsedBass.pitch
        }
        return .chord(
            Chord(root: root, quality: quality, bass: bass)
                .transposed(by: max(0, sourceCapo))
        )
    }

    /// True when the suffix already says what the third is, so a lowercase
    /// degree must not prepend another one.
    private static func startsWithExplicitThird(_ suffix: String) -> Bool {
        let lowered = suffix.lowercased()
        return ["m", "min", "-", "dim", "°", "sus", "aug", "+", "maj", "ma", "Δ"]
            .contains { lowered.hasPrefix($0) }
    }

    private static func quality(for source: String) -> ChordQuality? {
        let raw = source
            .replacingOccurrences(of: "−", with: "m")
            .replacingOccurrences(of: "-", with: "m")
            .replacingOccurrences(of: "Δ", with: "maj")
            .replacingOccurrences(of: "ø", with: "m7b5")
            .lowercased()
        let normalized = raw
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return switch normalized {
        case "", "maj", "major": .major
        case "m", "min", "minor": .minor
        case "7", "dom7": .dominantSeventh
        case "m7", "min7": .minorSeventh
        case "maj7", "ma7", "major7": .majorSeventh
        case "sus", "sus4": .suspendedFourth
        case "sus2": .suspendedSecond
        case "dim", "°": .diminished
        case "dim7", "°7": .diminishedSeventh
        case "aug", "+": .augmented
        case "m7b5", "min7b5": .halfDiminished
        case "5": .power
        case "6": .sixth
        case "m6", "min6": .minorSixth
        case "9": .ninth
        case "maj9", "ma9": .majorNinth
        case "m9", "min9": .minorNinth
        case "add2": .addSecond
        case "add4": .addFourth
        case "add9": .addNinth
        case "b5": .flatFifth
        case "#5": .sharpFifth
        default: nil
        }
    }

    private static func notePrefix(_ source: String) -> (pitch: Int, length: Int)? {
        guard let first = source.first else { return nil }
        let bases: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard var pitch = bases[Character(first.uppercased())] else { return nil }
        var length = 1
        if source.count > 1 {
            let accidental = source[source.index(after: source.startIndex)]
            if accidental == "#" { pitch += 1; length += 1 }
            if accidental == "b" { pitch -= 1; length += 1 }
        }
        return (PitchClass.normalized(pitch), length)
    }

    private static func degreeRoot(
        _ source: String,
        key: MusicalKey?
    ) -> (root: Int, remainder: String, isMinorByDefault: Bool)? {
        guard let key else { return nil }
        // Nashville and Roman both write the accidental *before* the degree:
        // `b3`, `♭VII`. Reading it after the digit meant a flattened degree
        // never parsed at all.
        var body = source
        var alteration = 0
        if body.hasPrefix("b") || body.hasPrefix("♭") { alteration = -1; body.removeFirst() }
        else if body.hasPrefix("#") || body.hasPrefix("♯") { alteration = 1; body.removeFirst() }

        if let first = body.first, let number = first.wholeNumberValue, (1...7).contains(number) {
            return (
                PitchClass.normalized(key.scalePitchClasses[number - 1] + alteration),
                String(body.dropFirst()),
                false
            )
        }
        let symbols = ["vii", "vi", "iv", "iii", "ii", "v", "i"]
        let lowered = body.lowercased()
        guard let symbol = symbols.first(where: { lowered.hasPrefix($0) }),
              let degree = ["i", "ii", "iii", "iv", "v", "vi", "vii"].firstIndex(of: symbol)
        else { return nil }
        let root = PitchClass.normalized(key.scalePitchClasses[degree] + alteration)
        return (
            root,
            String(body.dropFirst(symbol.count)),
            body.first?.isLowercase == true
        )
    }
}

// MARK: - Text formats

enum UserChordParser {
    static let maximumCharacters = 500_000

    /// What one line of a pasted chart turned out to be.
    ///
    /// Classifying the whole file before emitting anything is what lets a
    /// chord line know whether a lyric line follows it, and stops a two-word
    /// sung line from being read as two chords because both words happen to
    /// spell one.
    private enum LineKind {
        case blank
        case directive(String)
        case section(String)
        case tablature
        case annotation
        case grid
        case inline
        /// `unreadable` holds tokens on a chord line that are not chords. The
        /// line is still a chord line; those tokens are reported rather than
        /// taking the whole line down with them.
        case chords([ChordToken], unreadable: [String])
        case lyric
    }

    private struct ChordToken {
        var text: String
        /// Character column in the line, which is the column of the lyric
        /// beneath it.
        var column: Int
    }

    static func parse(_ source: String) -> ImportedChordDocument {
        let text = String(source.prefix(maximumCharacters))
            .replacingOccurrences(of: "\t", with: "    ")
        var document = ImportedChordDocument(originalText: text)
        let lines = text.components(separatedBy: .newlines)
        let kinds = lines.map(classify)

        var currentSection: String?
        var gridBar = 0

        for (lineIndex, rawLine) in lines.enumerated() {
            switch kinds[lineIndex] {
            case .blank:
                continue

            case .tablature:
                document.warnings.append(.init(
                    kind: .ignoredTab,
                    message: "Ignored a guitar tablature line.",
                    line: lineIndex + 1
                ))

            case .directive(let body):
                parseDirective(
                    body,
                    line: lineIndex,
                    document: &document,
                    currentSection: &currentSection
                )

            case .annotation:
                parsePlainMetadata(
                    rawLine.trimmingCharacters(in: .whitespaces),
                    line: lineIndex,
                    document: &document
                )

            case .section(let label):
                currentSection = label
                document.sections.append(
                    .init(name: label, firstEventIndex: document.events.count)
                )

            case .inline:
                parseInline(
                    rawLine,
                    line: lineIndex,
                    section: currentSection,
                    document: &document
                )

            case .grid:
                let before = document.events.count
                parseGrid(
                    rawLine.trimmingCharacters(in: .whitespaces),
                    startingBar: gridBar,
                    section: currentSection,
                    line: lineIndex,
                    document: &document
                )
                if document.events.count > before {
                    gridBar += max(
                        1,
                        rawLine.filter { $0 == "|" }.count - 1
                    )
                }

            case .chords(let tokens, let unreadable):
                for token in unreadable {
                    document.warnings.append(.init(
                        kind: .unknownChord,
                        message: "Could not read “\(token)” on a chord line. The chords around it were kept.",
                        line: lineIndex + 1
                    ))
                }
                // A chord line describes the line of words under it. Blank
                // lines between the two are layout, not separation.
                let target = lines.indices.dropFirst(lineIndex + 1).first {
                    if case .blank = kinds[$0] { return false }
                    return true
                }
                let lyricIndex: Int? = target.flatMap {
                    if case .lyric = kinds[$0] { return $0 }
                    return nil
                }
                for (ordinal, token) in tokens.enumerated() {
                    let location: ImportedChordLocation = lyricIndex.map {
                        .lyric(line: $0, character: token.column)
                    } ?? .ordinal(document.events.count + ordinal)
                    append(
                        token: token.text,
                        location: location,
                        section: currentSection,
                        line: lineIndex,
                        // A chord standing over words is placed by those words.
                        // One standing alone — an intro line, a turnaround — is
                        // only ordered, and says so.
                        confidence: lyricIndex == nil ? 0.6 : 0.95,
                        document: &document
                    )
                }

            case .lyric:
                document.lyricAnchors.append(.init(
                    lineIndex: lineIndex,
                    text: rawLine,
                    section: currentSection
                ))
            }
        }
        applySourceCapo(to: &document)
        return document
    }

    /// Moves printed shapes to sounding pitch once the whole file has been
    /// read.
    ///
    /// Doing it per chord as they were parsed made the result depend on where
    /// `{capo}` happened to appear: a capo line below the first chorus left
    /// everything above it a semitone-set wrong. `metadata` keeps the printed
    /// key and the source capo as provenance; the events are what sounds.
    private static func applySourceCapo(to document: inout ImportedChordDocument) {
        let capo = document.metadata.sourceCapo
        guard capo > 0 else { return }
        for index in document.events.indices {
            document.events[index].chord = document.events[index].chord?.transposed(by: capo)
        }
    }

    private static func classify(_ rawLine: String) -> LineKind {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }
        if isTab(trimmed) { return .tablature }
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return .directive(String(trimmed.dropFirst().dropLast()))
        }
        if let label = sectionLabel(trimmed) { return .section(label) }
        if trimmed.contains("["), trimmed.contains("]") { return .inline }
        if isPlainMetadata(trimmed) { return .annotation }
        if trimmed.contains("|"), isGrid(trimmed) { return .grid }
        let tokens = chordTokens(in: rawLine)
        let meaningful = meaningfulTokens(in: trimmed)
        if !tokens.isEmpty, tokens.count == meaningful.count {
            return .chords(tokens, unreadable: [])
        }
        // A line that is mostly chords is a chord line with something in it we
        // could not read — a typo, an annotation, two symbols that ran
        // together. Reading the whole line as lyrics instead threw away every
        // chord on it and said nothing, which is the one thing the parser must
        // never do.
        //
        // The wide-spacing test is what keeps ordinary words out: a chord line
        // is laid out in columns and has gaps in it, while "A B C of the
        // morning" is single-spaced whatever its first three words spell.
        if tokens.count >= 2, !meaningful.isEmpty,
           Double(tokens.count) / Double(meaningful.count) >= 0.6,
           hasColumnSpacing(rawLine) {
            let recognised = Set(tokens.map(\.text))
            return .chords(
                tokens,
                unreadable: meaningful.filter { !recognised.contains($0) }
            )
        }
        return .lyric
    }

    /// True when the line is laid out in columns rather than written as prose.
    private static func hasColumnSpacing(_ line: String) -> Bool {
        var run = 0
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == " " {
                run += 1
                if run >= 2 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// A bar grid, rather than a lyric line that merely contains a pipe.
    private static func isGrid(_ trimmed: String) -> Bool {
        let cells = trimmed.split(separator: "|").flatMap { meaningfulTokens(in: String($0)) }
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell == "." || cell == "-" || cell == "%" || cell == "%%"
                || isBareChord(cell)
        }
    }

    private static func parseDirective(
        _ raw: String,
        line: Int,
        document: inout ImportedChordDocument,
        currentSection: inout String?
    ) {
        let pair = raw.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let name = pair[0].lowercased().replacingOccurrences(of: "_", with: "-")
        let value = pair.count > 1 ? pair[1] : ""
        switch name {
        case "title", "t": document.metadata.title = value
        case "artist", "subtitle", "st": document.metadata.artist = value
        case "key":
            if case .chord(let chord) = ChordSymbolParser.parse(value, sourceCapo: 0) {
                document.metadata.key = MusicalKey(tonic: chord.root, isMinor: chord.quality.base == .minor)
            } else {
                warnMetadata("Could not read the source key “\(value)”.", line: line, document: &document)
            }
        case "capo":
            if let capo = capoValue(in: value) {
                document.metadata.sourceCapo = capo
            } else {
                warnMetadata("Could not read the source capo “\(value)”.", line: line, document: &document)
            }
        case "tempo":
            if let tempo = Double(value), tempo > 0 { document.metadata.tempo = tempo }
            else { warnMetadata("Could not read the tempo “\(value)”.", line: line, document: &document) }
        case "duration":
            document.metadata.duration = parseDuration(value)
        case "time":
            let values = value.split(separator: "/")
            if values.count == 2 {
                document.metadata.beatsPerBar = Int(values[0])
                document.metadata.beatUnit = Int(values[1])
            } else {
                warnMetadata("Could not read the time signature “\(value)”.", line: line, document: &document)
            }
        case "start-of-verse", "sov", "start-of-chorus", "soc", "start-of-bridge":
            currentSection = value.isEmpty
                ? name.replacingOccurrences(of: "start-of-", with: "").capitalized
                : value
            document.sections.append(.init(
                name: currentSection!,
                firstEventIndex: document.events.count
            ))
        case "end-of-verse", "eov", "end-of-chorus", "eoc", "end-of-bridge":
            currentSection = nil
        case "comment", "c", "comment-italic", "ci", "comment-box", "cb":
            break
        default:
            document.warnings.append(.init(
                kind: .unknownDirective,
                message: "Preserved unsupported directive “{\(raw)}”.",
                line: line + 1
            ))
        }
    }

    private static func parseInline(
        _ raw: String,
        line: Int,
        section: String?,
        document: inout ImportedChordDocument
    ) {
        var lyric = ""
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard raw[cursor] == "[",
                  let close = raw[cursor...].firstIndex(of: "]") else {
                lyric.append(raw[cursor])
                cursor = raw.index(after: cursor)
                continue
            }
            let symbol = String(raw[raw.index(after: cursor)..<close])
            append(
                token: symbol,
                location: .lyric(line: line, character: lyric.count),
                section: section,
                line: line,
                confidence: 1,
                document: &document
            )
            cursor = raw.index(after: close)
        }
        if !lyric.trimmingCharacters(in: .whitespaces).isEmpty {
            document.lyricAnchors.append(.init(lineIndex: line, text: lyric, section: section))
        }
    }

    private static func parseGrid(
        _ raw: String,
        startingBar: Int,
        section: String?,
        line: Int,
        document: inout ImportedChordDocument
    ) {
        let bars = raw.split(separator: "|", omittingEmptySubsequences: false)
        var barNumber = startingBar
        for bar in bars {
            let tokens = meaningfulTokens(in: String(bar))
            guard !tokens.isEmpty else { continue }
            if tokens == ["%"] || tokens == ["%%"] {
                let repeatedBars = tokens == ["%%"] ? 2 : 1
                for sourceBar in max(0, barNumber - repeatedBars)..<barNumber {
                    let previous = document.events.filter {
                        guard case .grid(let eventBar, _) = $0.location else { return false }
                        return eventBar == sourceBar
                    }
                    for event in previous {
                        guard case .grid(_, let beat) = event.location else { continue }
                        var repeated = event
                        repeated.id = UUID()
                        repeated.location = .grid(bar: barNumber, beat: beat)
                        document.events.append(repeated)
                    }
                    barNumber += 1
                }
                continue
            }
            var lastSymbol: String?
            for (beat, token) in tokens.enumerated() {
                if token == "." || token == "-" { continue }
                if token == "%" {
                    guard let lastSymbol else { continue }
                    append(
                        token: lastSymbol,
                        location: .grid(bar: barNumber, beat: Double(beat)),
                        section: section,
                        line: line,
                        confidence: 1,
                        document: &document
                    )
                    continue
                }
                lastSymbol = token
                append(
                    token: token,
                    location: .grid(bar: barNumber, beat: Double(beat)),
                    section: section,
                    line: line,
                    confidence: 1,
                    document: &document
                )
            }
            barNumber += 1
        }
    }

    private static func append(
        token: String,
        location: ImportedChordLocation,
        section: String?,
        line: Int,
        confidence: Double,
        document: inout ImportedChordDocument
    ) {
        guard let parsed = parsedChord(token, key: document.metadata.key) else {
            document.warnings.append(.init(
                kind: .unknownChord,
                message: "Could not read chord “\(token)”.",
                line: line + 1
            ))
            return
        }
        document.events.append(.init(
            chord: parsed.chord,
            printedSymbol: token,
            location: location,
            parseConfidence: confidence,
            section: section
        ))
    }

    /// Reads a symbol the author marked as a chord — bracketed, or in a grid
    /// cell — where degrees are unambiguous. Capo is applied afterwards, once.
    private static func parsedChord(
        _ token: String,
        key: MusicalKey?
    ) -> (chord: Chord?, isNoChord: Bool)? {
        switch ChordSymbolParser.parse(token, key: key, sourceCapo: 0) {
        case .chord(let chord): (chord, false)
        case .noChord: (nil, true)
        case nil: nil
        }
    }

    /// A chord as written in unmarked text.
    ///
    /// Stricter than a bracketed symbol on purpose. The root must be written
    /// the way charts write it — a capital A to G — and degrees are not
    /// accepted at all, because "I", "am" and "be" are words far more often
    /// than they are chords.
    private static func isBareChord(_ token: String) -> Bool {
        let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "|,()"))
        guard let first = stripped.first, ("A"..."G").contains(String(first)),
              stripped.count <= 12 else { return false }
        return ChordSymbolParser.parse(stripped, key: nil, allowsDegrees: false) != nil
    }

    private static func chordTokens(in line: String) -> [ChordToken] {
        var result: [ChordToken] = []
        var index = line.startIndex
        while index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            let token = String(line[start..<index])
                .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            if isBareChord(token) {
                result.append(
                    ChordToken(
                        text: token.trimmingCharacters(in: CharacterSet(charactersIn: ",()")),
                        column: line.distance(from: line.startIndex, to: start)
                    )
                )
            }
        }
        return result
    }

    private static func meaningfulTokens(in line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
            let lowered = token.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
            if ["repeat", ":||", "||:", "|:", ":|", "*"].contains(lowered) { return false }
            // "x2", "3x", "x 4" — how a chart says "again", not a chord.
            if lowered.count <= 3,
               lowered.hasPrefix("x") || lowered.hasSuffix("x"),
               lowered.contains(where: \.isNumber) { return false }
            return true
        }
    }

    /// Header lines a chart site prints above the chart itself.
    private static func isPlainMetadata(_ trimmed: String) -> Bool {
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("capo") { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let name = trimmed[trimmed.startIndex..<colon]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return [
            "title", "song", "artist", "band", "album", "key", "tuning",
            "tempo", "bpm", "difficulty", "author", "transcribed by",
        ].contains(name)
    }

    private static func parsePlainMetadata(
        _ trimmed: String,
        line: Int,
        document: inout ImportedChordDocument
    ) {
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("capo") {
            // "Capo: 2nd fret", "Capo 2", "capo on 3rd fret", "No capo".
            document.metadata.sourceCapo = capoValue(in: trimmed) ?? 0
            return
        }
        guard let colon = trimmed.firstIndex(of: ":") else { return }
        let name = trimmed[trimmed.startIndex..<colon]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        switch name {
        case "title", "song": document.metadata.title = value
        case "artist", "band": document.metadata.artist = value
        case "key":
            if case .chord(let chord) = ChordSymbolParser.parse(value, allowsDegrees: false) {
                document.metadata.key = MusicalKey(
                    tonic: chord.root,
                    isMinor: chord.quality.base == .minor
                )
            }
        case "tempo", "bpm":
            if let tempo = Double(value.filter { $0.isNumber || $0 == "." }), tempo > 0 {
                document.metadata.tempo = tempo
            }
        default:
            break
        }
    }

    /// The fret number in a capo line, however it is written.
    private static func capoValue(in source: String) -> Int? {
        let lowered = source.lowercased()
        if lowered.contains("no capo") || lowered.contains("none") { return 0 }
        let romanFrets = ["xii": 12, "xi": 11, "ix": 9, "viii": 8, "vii": 7,
                          "vi": 6, "iv": 4, "iii": 3, "ii": 2, "x": 10, "v": 5, "i": 1]
        var digits = ""
        for character in lowered {
            if character.isNumber { digits.append(character) }
            else if !digits.isEmpty { break }
        }
        if let value = Int(digits), (0...12).contains(value) { return value }
        for (symbol, value) in romanFrets.sorted(by: { $0.key.count > $1.key.count })
        where lowered.contains(" \(symbol)") || lowered.hasSuffix(symbol) {
            return value
        }
        return nil
    }

    private static func sectionLabel(_ source: String) -> String? {
        guard source.hasPrefix("["), source.hasSuffix("]"), !source.contains("][") else { return nil }
        let value = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !isBareChord(value) else { return nil }
        return value
    }

    private static func isTab(_ source: String) -> Bool {
        let lower = source.lowercased()
        if ["e|", "b|", "g|", "d|", "a|"].contains(where: lower.hasPrefix) { return true }
        let digits = source.filter(\.isNumber).count
        return source.contains("---") && digits > 1
    }

    private static func parseDuration(_ source: String) -> TimeInterval? {
        let components = source.split(separator: ":").compactMap { Double($0) }
        if components.count == 2 { return components[0] * 60 + components[1] }
        return Double(source)
    }

    private static func warnMetadata(
        _ message: String,
        line: Int,
        document: inout ImportedChordDocument
    ) {
        document.warnings.append(.init(kind: .malformedMetadata, message: message, line: line + 1))
    }
}
// MARK: - Local alignment

/// Turns a parsed chart into timings for the recording that is open.
///
/// The evidence is used strongest-first — a matched word with a timestamp, a
/// matched line, an explicit bar on a reliable grid, the audio itself, and only
/// then an interpolation that says it is one. Whatever wins, the supplied chord
/// label is never changed: this decides *when*, never *what*.
enum UserChordAligner {
    struct Result: Sendable {
        var chords: SongChords
        var alignment: ChordChartAlignment
    }

    /// Two chords that resolve to the same instant are still two chords.
    /// `Bm7` and `E` on the same syllable are pushed this far apart so neither
    /// is swallowed by `sanitize`, which drops anything shorter than a
    /// hundredth of a second.
    private static let minimumSpacing: TimeInterval = 0.08
    /// How alike two lines have to read before they are called the same line.
    private static let lineMatchThreshold = 0.4

    private struct Placement {
        var time: TimeInterval
        var confidence: Double
        var isEstimated: Bool
    }

    private struct LyricMatch {
        /// Index into `lyrics.lines`.
        var index: Int
        var score: Double
    }

    /// - Parameters:
    ///   - reference: the local analysis of this recording, when there is one.
    ///     Used only to notice that the chart is in another key — never to
    ///     rename a chord.
    ///   - pitchOffset: semitones to move the whole chart by, which the user
    ///     chooses after being told what the recording suggests.
    static func align(
        _ document: ImportedChordDocument,
        lyrics: SongLyrics?,
        grid: BeatGrid?,
        duration: TimeInterval,
        evidence: [BeatChordEvidence] = [],
        reference: SongChords? = nil,
        pitchOffset: Int = 0
    ) -> Result? {
        guard !document.events.isEmpty, duration > 0 else { return nil }
        let anchors = Dictionary(
            document.lyricAnchors.map { ($0.lineIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let matches = matchLyricLines(document.lyricAnchors, to: lyrics)

        // A bar number in a chart with words is not a bar number in the
        // recording. `| Em | Em |` under an "Interlude" heading means four bars
        // *of the interlude*, not bars one to four of the song — and reading it
        // as the latter sent every instrumental section back to the first
        // thirty seconds. Absolute bars are only trusted when the chart is
        // nothing but bars, with no words to place it by.
        let usesAbsoluteBars = matches.isEmpty
        let barOffset = usesAbsoluteBars
            ? startingBar(
                events: document.events,
                grid: grid,
                reference: reference,
                evidence: evidence,
                pitchOffset: pitchOffset
              )
            : 0
        var placements = [Placement?](repeating: nil, count: document.events.count)
        for (index, event) in document.events.enumerated() {
            if let lyrics,
               case .lyric(let line, let character) = event.location,
               let anchor = anchors[line],
               let match = matches[line] {
                placements[index] = lyricPlacement(
                    character: character,
                    anchor: anchor,
                    match: match,
                    lyrics: lyrics
                )
            }
            if placements[index] == nil, usesAbsoluteBars,
               let time = gridTime(event.location, grid: grid, barOffset: barOffset) {
                placements[index] = Placement(time: time, confidence: 0.9, isEstimated: false)
            }
        }
        // Audio only fills what the words and bars could not, and only inside
        // the window its neighbours leave open. That keeps the search small and
        // stops one confident chroma match from dragging a whole verse.
        applyAudioPlacements(
            &placements,
            events: document.events,
            evidence: evidence,
            duration: duration
        )
        let completed = fillGaps(
            placements,
            events: document.events,
            beatsPerBar: document.metadata.beatsPerBar ?? 4,
            duration: duration
        )
        let ordered = enforceOrder(completed, duration: duration)

        var segments: [ChordSegment] = []
        segments.reserveCapacity(ordered.count)
        for index in ordered.indices {
            let start = ordered[index].time
            let end = index + 1 < ordered.count ? ordered[index + 1].time : duration
            guard end > start else { continue }
            segments.append(.init(
                start: start,
                end: end,
                chord: document.events[index].chord?.transposed(by: pitchOffset),
                confidence: ordered[index].confidence
            ))
        }
        var chords = SongChords(
            segments: segments,
            key: document.metadata.key.map {
                $0.transposed(by: document.metadata.sourceCapo + pitchOffset)
            },
            confidence: ordered.map(\.confidence).reduce(0, +) / Double(max(1, ordered.count))
        )
        chords.sanitize(duration: duration)

        return Result(
            chords: chords,
            alignment: measure(
                document: document,
                placements: ordered,
                matches: matches,
                grid: usesAbsoluteBars ? grid : nil,
                barOffset: barOffset,
                evidence: evidence,
                duration: duration,
                chords: chords,
                reference: reference,
                pitchOffset: pitchOffset
            )
        )
    }

    /// How well the chart and the recording's own analysis agree on the root,
    /// at the current pitch and at every other.
    ///
    /// A chart written a semitone above the record — a tuned-down guitar, a
    /// capo the transcriber assumed — places every chord correctly and still
    /// sounds wrong under the fingers. The evidence for it is unmissable once
    /// looked for: agreement jumps from near nothing to most of the song at one
    /// particular shift. Nothing is moved automatically; the user is told.
    private static func pitchComparison(
        _ chords: SongChords,
        reference: SongChords?,
        duration: TimeInterval
    ) -> (best: Int, bestScore: Double, currentScore: Double)? {
        guard let reference, !reference.isEmpty, !chords.isEmpty, duration > 0 else {
            return nil
        }
        var totals = [Double](repeating: 0, count: 12)
        var samples = 0.0
        var time = 0.0
        while time < duration {
            defer { time += 0.25 }
            guard let mine = chords.segment(at: time)?.chord,
                  let theirs = reference.segment(at: time)?.chord else { continue }
            samples += 1
            totals[PitchClass.normalized(theirs.root - mine.root)] += 1
        }
        guard samples >= 40 else { return nil }
        let scores = totals.map { $0 / samples }
        var best = 0
        for shift in scores.indices where scores[shift] > scores[best] { best = shift }
        return (best > 6 ? best - 12 : best, scores[best], scores[0])
    }

    // MARK: - Lyric matching

    /// Matches the chart's lines to the song's lines in order.
    ///
    /// A greedy best-match per line cannot tell the second chorus from the
    /// first: both read the same, so both land on whichever occurrence it looks
    /// at first. This is a global alignment instead — every chart line and song
    /// line is used at most once, in order, and the path that scores best over
    /// the whole song wins. Skipping is allowed on both sides, because a chart
    /// routinely writes a chorus once for a recording that sings it three
    /// times, and a recording routinely has lines the chart never printed.
    private static func matchLyricLines(
        _ anchors: [ImportedLyricAnchor],
        to lyrics: SongLyrics?
    ) -> [Int: LyricMatch] {
        guard let lyrics, !anchors.isEmpty else { return [:] }
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isSection }
        guard !sung.isEmpty else { return [:] }

        let sections = sectionLabels(of: lyrics)
        let anchorWords = anchors.map { words($0.text) }
        let lineWords = sung.map { words(lyrics.lines[$0].text) }
        let rows = anchors.count
        let columns = sung.count
        // A chart line the recording never sings is a real cost; a recording
        // line the chart never printed is nearly free, since condensed charts
        // are the norm.
        let skipAnchor = -0.35
        let skipLine = -0.03

        var score = Array(
            repeating: [Double](repeating: 0, count: columns + 1),
            count: rows + 1
        )
        var choice = Array(
            repeating: [UInt8](repeating: 0, count: columns + 1),
            count: rows + 1
        )
        for row in 1...rows {
            score[row][0] = score[row - 1][0] + skipAnchor
            choice[row][0] = 1
        }
        for column in 1...columns {
            score[0][column] = score[0][column - 1] + skipLine
            choice[0][column] = 2
        }
        for row in 1...rows {
            for column in 1...columns {
                let pairing = pairScore(
                    anchor: anchors[row - 1],
                    anchorWords: anchorWords[row - 1],
                    lineWords: lineWords[column - 1],
                    lineSection: sections[sung[column - 1]]
                )
                let diagonal = score[row - 1][column - 1] + pairing
                let up = score[row - 1][column] + skipAnchor
                let left = score[row][column - 1] + skipLine
                if diagonal >= up, diagonal >= left {
                    score[row][column] = diagonal
                    choice[row][column] = 0
                } else if up >= left {
                    score[row][column] = up
                    choice[row][column] = 1
                } else {
                    score[row][column] = left
                    choice[row][column] = 2
                }
            }
        }

        var result: [Int: LyricMatch] = [:]
        var row = rows
        var column = columns
        while row > 0, column > 0 {
            switch choice[row][column] {
            case 0:
                let similarity = similarity(anchorWords[row - 1], lineWords[column - 1])
                if similarity >= lineMatchThreshold {
                    result[anchors[row - 1].lineIndex] = LyricMatch(
                        index: sung[column - 1],
                        score: similarity
                    )
                }
                row -= 1
                column -= 1
            case 1:
                row -= 1
            default:
                column -= 1
            }
        }
        return result
    }

    private static func pairScore(
        anchor: ImportedLyricAnchor,
        anchorWords: Set<String>,
        lineWords: Set<String>,
        lineSection: String?
    ) -> Double {
        let similarity = similarity(anchorWords, lineWords)
        guard similarity >= lineMatchThreshold else { return -0.5 }
        // Section names are the tie-breaker a repeated chorus needs: identical
        // words in a run labelled "Chorus 2" belong to the chart's second
        // chorus, not its first.
        guard let lineSection, let anchorSection = anchor.section else { return similarity }
        return similarity + (lineSection.caseInsensitiveCompare(anchorSection) == .orderedSame
            ? 0.2
            : -0.05)
    }

    /// Which section each sung line falls under, from the section markers
    /// already in the song's own lyrics.
    private static func sectionLabels(of lyrics: SongLyrics) -> [Int: String] {
        var result: [Int: String] = [:]
        var current: String?
        for index in lyrics.lines.indices {
            if let label = lyrics.lines[index].sectionLabel {
                current = label
            } else if let current {
                result[index] = current
            }
        }
        return result
    }

    /// Where one chord lands inside a line the recording sings.
    ///
    /// The chord's column belongs to the *chart's* text. Reading that column
    /// straight into the recording's line put chords on the wrong word whenever
    /// the two spellings differed — which is most of the time, since fuzzy
    /// matching exists precisely because they differ. So the column picks a
    /// word of the chart's line, and the two lines' words are aligned to each
    /// other to find its counterpart.
    private static func lyricPlacement(
        character: Int,
        anchor: ImportedLyricAnchor,
        match: LyricMatch,
        lyrics: SongLyrics
    ) -> Placement? {
        guard lyrics.lines.indices.contains(match.index) else { return nil }
        let line = lyrics.lines[match.index]
        let importedWords = wordSpans(anchor.text)
        let targetWords = wordSpans(line.text)
        guard !targetWords.isEmpty else { return nil }

        let importedIndex = wordIndex(at: character, in: importedWords)
        let mapping = alignWords(
            importedWords.map(\.normalized),
            targetWords.map(\.normalized)
        )
        let targetIndex = mapping.indices.contains(importedIndex)
            ? mapping[importedIndex]
            : targetWords.count - 1

        if !line.words.isEmpty {
            // Word timings do not always come one-per-token — a caption may
            // group them — so scale rather than assume.
            let wordIndex = line.words.count == targetWords.count
                ? targetIndex
                : scaled(targetIndex, from: targetWords.count, to: line.words.count)
            let word = line.words[min(max(0, wordIndex), line.words.count - 1)]
            return Placement(
                time: word.start + lyrics.offset,
                confidence: 0.97 * match.score,
                isEstimated: false
            )
        }

        guard let start = lyrics.effectiveStart(of: line) else { return nil }
        let end = lineEnd(
            at: match.index,
            in: lyrics,
            start: start,
            wordCount: targetWords.count
        )
        let fraction = Double(targetIndex) / Double(max(1, targetWords.count))
        return Placement(
            time: start + (end - start) * fraction,
            confidence: 0.72 * match.score,
            isEstimated: true
        )
    }

    /// When the words of a line stop.
    ///
    /// With no word timings the only certain moment is where the line starts,
    /// and the obvious end — where the next line starts — is wrong whenever
    /// anything happens in between. A line sung in three seconds followed by a
    /// four-bar fill would have its chords smeared across seven, so every chord
    /// after the first word drifted late. The gap is therefore capped at what
    /// the song's own timed lines suggest those words take to sing.
    private static func lineEnd(
        at index: Int,
        in lyrics: SongLyrics,
        start: TimeInterval,
        wordCount: Int
    ) -> TimeInterval {
        if let end = lyrics.lines[index].end { return end + lyrics.offset }
        var next: TimeInterval?
        for candidate in (index + 1)..<lyrics.lines.count {
            guard !lyrics.lines[candidate].isSection,
                  let nextStart = lyrics.effectiveStart(of: lyrics.lines[candidate]),
                  nextStart > start else { continue }
            next = nextStart
            break
        }
        let sung = Double(wordCount) * perWordEstimate(in: lyrics)
        guard let next else { return start + sung }
        return min(next, start + sung)
    }

    /// How long one word takes in this song, from the lines that are timed.
    ///
    /// Measured rather than assumed: a ballad and a fast talker need different
    /// numbers, and the song has already said which it is. Only gaps short
    /// enough to be one line of singing are counted, so the pause before a solo
    /// does not inflate the estimate it is meant to defend against.
    private static func perWordEstimate(in lyrics: SongLyrics) -> TimeInterval {
        var samples: [TimeInterval] = []
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].isSection }
        for (index, next) in zip(sung, sung.dropFirst()) {
            guard let start = lyrics.effectiveStart(atIndex: index),
                  let end = lyrics.effectiveStart(atIndex: next),
                  end > start, end - start < 8 else { continue }
            let words = lyrics.lines[index].text
                .split(whereSeparator: \.isWhitespace).count
            guard words > 0 else { continue }
            samples.append((end - start) / Double(words))
        }
        guard !samples.isEmpty else { return 0.4 }
        return samples.sorted()[samples.count / 2]
    }

    /// Aligns two word sequences, so word *n* of the chart's line can be found
    /// in the recording's line even when a word was added, dropped, or
    /// misspelled. Every imported word gets an answer: matched words their
    /// counterpart, unmatched words the position between their neighbours.
    private static func alignWords(_ imported: [String], _ target: [String]) -> [Int] {
        guard !imported.isEmpty, !target.isEmpty else { return [] }
        let rows = imported.count
        let columns = target.count
        let gap = -0.6
        var score = Array(
            repeating: [Double](repeating: 0, count: columns + 1),
            count: rows + 1
        )
        var choice = Array(
            repeating: [UInt8](repeating: 0, count: columns + 1),
            count: rows + 1
        )
        for row in 1...rows {
            score[row][0] = score[row - 1][0] + gap
            choice[row][0] = 1
        }
        for column in 1...columns {
            score[0][column] = score[0][column - 1] + gap
            choice[0][column] = 2
        }
        for row in 1...rows {
            for column in 1...columns {
                let same = imported[row - 1] == target[column - 1] ? 1.0 : -0.5
                let diagonal = score[row - 1][column - 1] + same
                let up = score[row - 1][column] + gap
                let left = score[row][column - 1] + gap
                if diagonal >= up, diagonal >= left {
                    score[row][column] = diagonal
                    choice[row][column] = 0
                } else if up >= left {
                    score[row][column] = up
                    choice[row][column] = 1
                } else {
                    score[row][column] = left
                    choice[row][column] = 2
                }
            }
        }

        var matched = [Int?](repeating: nil, count: rows)
        var row = rows
        var column = columns
        while row > 0, column > 0 {
            switch choice[row][column] {
            case 0:
                if imported[row - 1] == target[column - 1] { matched[row - 1] = column - 1 }
                row -= 1
                column -= 1
            case 1:
                row -= 1
            default:
                column -= 1
            }
        }
        return filled(matched, columns: columns)
    }

    /// Gives every unmatched word a position: between its matched neighbours
    /// where there are any, proportional where there are none.
    private static func filled(_ matched: [Int?], columns: Int) -> [Int] {
        let anchors = matched.indices.filter { matched[$0] != nil }
        guard let first = anchors.first, let last = anchors.last else {
            return matched.indices.map {
                scaled($0, from: matched.count, to: columns)
            }
        }
        var result = [Int](repeating: 0, count: matched.count)
        for index in matched.indices {
            if let value = matched[index] {
                result[index] = value
            } else if index < first {
                result[index] = max(0, matched[first]! - (first - index))
            } else if index > last {
                result[index] = min(columns - 1, matched[last]! + (index - last))
            } else {
                let before = anchors.last { $0 < index }!
                let after = anchors.first { $0 > index }!
                let span = Double(after - before)
                let fraction = Double(index - before) / span
                let low = Double(matched[before]!)
                let high = Double(matched[after]!)
                result[index] = Int((low + (high - low) * fraction).rounded())
            }
            result[index] = min(max(0, result[index]), columns - 1)
        }
        return result
    }

    private static func scaled(_ index: Int, from source: Int, to target: Int) -> Int {
        guard source > 1, target > 0 else { return 0 }
        let fraction = Double(index) / Double(source - 1)
        return min(target - 1, max(0, Int((fraction * Double(target - 1)).rounded())))
    }

    // MARK: - Bars

    /// Which bar of the recording the chart's first bar is.
    ///
    /// A bar chart counts its own bars from one, and a transcriber routinely
    /// starts counting where the song's *chart* starts rather than where its
    /// audio does — the four-bar intro nobody wrote down, the count-in, the
    /// fade. Reading bar one as the recording's bar one then puts the whole
    /// chart a fixed distance early and leaves it there.
    ///
    /// The offset is found rather than assumed, by sliding the chart along the
    /// downbeats and keeping the position where its chords best match what the
    /// recording is actually doing. Only the placement moves; the chart's
    /// labels are never involved in the decision.
    private static func startingBar(
        events: [ImportedChordEvent],
        grid: BeatGrid?,
        reference: SongChords?,
        evidence: [BeatChordEvidence],
        pitchOffset: Int
    ) -> Int {
        guard let grid, grid.isReliable else { return 0 }
        guard reference != nil || !evidence.isEmpty else { return 0 }
        let downbeats = grid.beats.indices.filter { grid.beats[$0].isDownbeat }
        let bars: [(bar: Int, chord: Chord)] = events.compactMap { event in
            guard case .grid(let bar, _) = event.location,
                  let chord = event.chord?.transposed(by: pitchOffset) else { return nil }
            return (bar, chord)
        }
        guard bars.count >= 4,
              let highest = bars.map(\.bar).max(),
              downbeats.count > highest else { return 0 }

        // Sliding further than the chart is long would be matching it against
        // a different part of the song entirely.
        let limit = min(downbeats.count - 1 - highest, max(8, highest))
        guard limit > 0 else { return 0 }

        var best = 0
        var bestScore = -Double.infinity
        for offset in 0...limit {
            var score = 0.0
            for entry in bars {
                let index = downbeats[entry.bar + offset]
                guard grid.beats.indices.contains(index) else { continue }
                let time = grid.beats[index].time
                if let reference {
                    guard let heard = reference.segment(at: time)?.chord else { continue }
                    score += heard.root == entry.chord.root ? 1 : 0
                } else if !evidence.isEmpty {
                    score += evidence[nearestBeat(to: time, in: evidence)]
                        .agreement(with: entry.chord)
                }
            }
            // A tie goes to no offset: the chart said bar one, and only clear
            // evidence should overrule it.
            if score > bestScore + 0.0001 {
                bestScore = score
                best = offset
            }
        }
        return best
    }

    private static func gridTime(
        _ location: ImportedChordLocation,
        grid: BeatGrid?,
        barOffset: Int = 0
    ) -> TimeInterval? {
        guard case .grid(let bar, let beat) = location,
              let grid, grid.isReliable else { return nil }
        let downbeats = grid.beats.indices.filter { grid.beats[$0].isDownbeat }
        guard downbeats.indices.contains(bar + barOffset) else { return nil }
        let start = downbeats[bar + barOffset]
        let index = start + Int(beat.rounded(.down))
        guard grid.beats.indices.contains(index) else { return nil }
        let base = grid.beats[index].time
        let fraction = beat - beat.rounded(.down)
        return base + fraction * (grid.secondsPerBeat ?? 0)
    }

    // MARK: - Audio

    /// Places the runs the words and bars left open, using the recording.
    ///
    /// Each run is solved inside the window its resolved neighbours leave, so
    /// the search is both smaller and better constrained than one pass over the
    /// whole song: an unplaced turnaround between two matched lines can only
    /// land between those two lines.
    private static func applyAudioPlacements(
        _ placements: inout [Placement?],
        events: [ImportedChordEvent],
        evidence: [BeatChordEvidence],
        duration: TimeInterval
    ) {
        guard !evidence.isEmpty else { return }
        var index = 0
        while index < placements.count {
            guard placements[index] == nil else {
                index += 1
                continue
            }
            var end = index
            while end < placements.count, placements[end] == nil { end += 1 }
            defer { index = end }

            let lower = index > 0 ? placements[index - 1]!.time : 0
            let upper = end < placements.count ? placements[end]!.time : duration
            let window = evidence.filter { $0.start >= lower && $0.start <= upper }
            let run = Array(events[index..<end])
            // The table is one Double and one Int per event per beat. A long
            // chart against a long song is refused rather than allowed to
            // allocate hundreds of megabytes during a preview.
            guard window.count >= run.count, run.count * window.count <= 1_000_000 else {
                continue
            }
            let times = constrainedAudioPlacements(events: run, evidence: window)
            for (offset, event) in run.enumerated() {
                guard let time = times[event.id] else { continue }
                placements[index + offset] = Placement(
                    time: time,
                    confidence: 0.68,
                    isEstimated: false
                )
            }
        }
    }

    /// Maps an ordered supplied chart onto beats with hold/advance transitions.
    ///
    /// The dynamic program never chooses a different chord. It only chooses
    /// which beat best supports each event, and its monotonic transition keeps
    /// repeated sections distinct instead of snapping every occurrence to the
    /// first matching harmony.
    private static func constrainedAudioPlacements(
        events: [ImportedChordEvent],
        evidence: [BeatChordEvidence]
    ) -> [UUID: TimeInterval] {
        guard !events.isEmpty, !evidence.isEmpty else { return [:] }
        let eventCount = events.count
        let beatCount = evidence.count
        var previous = evidence.indices.map {
            evidence[$0].agreement(with: events[0].chord)
                - abs(Double($0) / Double(max(1, beatCount - 1))) * 0.08
        }
        var backPointers = Array(
            repeating: [Int](repeating: 0, count: beatCount),
            count: eventCount
        )
        if eventCount > 1 {
            for eventIndex in 1..<eventCount {
                var current = [Double](repeating: -.infinity, count: beatCount)
                var bestValue = -Double.infinity
                var bestIndex = 0
                for beatIndex in evidence.indices {
                    // The running maximum is what makes this monotonic: an
                    // event may only take a beat at or after the one its
                    // predecessor took. The small positive term biases ties
                    // towards the latest such beat, so held chords do not all
                    // collapse onto the first.
                    let candidate = previous[beatIndex] + Double(beatIndex) * 0.002
                    if candidate > bestValue {
                        bestValue = candidate
                        bestIndex = beatIndex
                    }
                    let expected = Double(eventIndex) / Double(max(1, eventCount - 1))
                    let observed = Double(beatIndex) / Double(max(1, beatCount - 1))
                    let orderPrior = -abs(expected - observed) * 0.12
                    current[beatIndex] = bestValue
                        - Double(beatIndex) * 0.002
                        + evidence[beatIndex].agreement(with: events[eventIndex].chord)
                        + orderPrior
                    backPointers[eventIndex][beatIndex] = bestIndex
                }
                previous = current
            }
        }
        var beatIndex = previous.indices.max(by: { previous[$0] < previous[$1] }) ?? 0
        var result: [UUID: TimeInterval] = [:]
        for eventIndex in events.indices.reversed() {
            result[events[eventIndex].id] = evidence[beatIndex].start
            if eventIndex > 0 { beatIndex = backPointers[eventIndex][beatIndex] }
        }
        return result
    }

    // MARK: - Filling and ordering

    /// Gives the still-unplaced events a time between the ones around them.
    ///
    /// Spreading them evenly across the *whole song* — what this used to do —
    /// is the worst possible guess: one unmatched line in a verse would be sent
    /// to the middle of the recording. Between its neighbours it is at least in
    /// the right part of the song, and it is labelled either way.
    private static func fillGaps(
        _ placements: [Placement?],
        events: [ImportedChordEvent],
        beatsPerBar: Int,
        duration: TimeInterval
    ) -> [Placement] {
        let anchors = placements.indices.filter { placements[$0] != nil }
        guard let first = anchors.first, let last = anchors.last else {
            return placements.indices.map { index in
                Placement(
                    time: duration * Double(index) / Double(max(1, placements.count)),
                    confidence: 0.3,
                    isEstimated: true
                )
            }
        }
        var result = placements
        if first > 0 {
            let end = placements[first]!.time
            for index in 0..<first {
                result[index] = Placement(
                    time: end * Double(index) / Double(first),
                    confidence: 0.4,
                    isEstimated: true
                )
            }
        }
        for (before, after) in zip(anchors, anchors.dropFirst()) where after - before > 1 {
            let start = placements[before]!.time
            let end = placements[after]!.time
            let run = (before + 1)..<after
            let fractions = fractions(for: run, events: events, beatsPerBar: beatsPerBar)
            for (offset, index) in run.enumerated() {
                result[index] = Placement(
                    time: start + (end - start) * fractions[offset],
                    confidence: 0.5,
                    isEstimated: true
                )
            }
        }
        if last < placements.count - 1 {
            let start = placements[last]!.time
            let span = max(0, duration - start)
            let count = placements.count - last
            for index in (last + 1)..<placements.count {
                result[index] = Placement(
                    time: start + span * Double(index - last) / Double(count),
                    confidence: 0.4,
                    isEstimated: true
                )
            }
        }
        return result.map { $0 ?? Placement(time: 0, confidence: 0.3, isEstimated: true) }
    }

    /// Where inside a gap each unplaced event belongs, as a fraction of it.
    ///
    /// Evenly by count is right for chords written over words. It is wrong for
    /// a written-out instrumental: `| C  Dsus2| Em |` is not three equal
    /// thirds, it is a bar holding two chords followed by a bar holding one.
    /// When every event in the run carries a bar and beat, their own musical
    /// spacing is used instead, extended by one average step at each end so
    /// they sit inside the gap rather than on top of its edges.
    private static func fractions(
        for run: Range<Int>,
        events: [ImportedChordEvent],
        beatsPerBar: Int
    ) -> [Double] {
        let count = run.count
        guard count > 0 else { return [] }
        let evenly = (1...count).map { Double($0) / Double(count + 1) }
        let positions: [Double] = run.compactMap { index in
            guard case .grid(let bar, let beat) = events[index].location else { return nil }
            return Double(bar * max(1, beatsPerBar)) + beat
        }
        guard positions.count == count, count > 1,
              let first = positions.first, let last = positions.last,
              last > first else { return evenly }
        let step = (last - first) / Double(count - 1)
        let span = (last + step) - (first - step)
        guard span > 0 else { return evenly }
        return positions.map { ($0 - (first - step)) / span }
    }

    /// Makes the chart run forwards.
    ///
    /// The chart's own order is the song's order, so it is kept rather than
    /// sorted by time — sorting would let one bad match reshuffle the chords
    /// around it. A placement that would go backwards is pushed just past its
    /// predecessor instead, and only called estimated when the push was large
    /// enough to be a disagreement rather than two chords on one syllable.
    private static func enforceOrder(
        _ placements: [Placement],
        duration: TimeInterval
    ) -> [Placement] {
        var result = placements
        var previous: TimeInterval?
        for index in result.indices {
            let ceiling = max(
                0,
                duration - minimumSpacing * Double(result.count - 1 - index)
            )
            var time = min(max(0, result[index].time), ceiling)
            if let previous, time < previous + minimumSpacing {
                let pushed = min(previous + minimumSpacing, ceiling)
                if pushed - time > 0.25 {
                    result[index].isEstimated = true
                    result[index].confidence = min(result[index].confidence, 0.45)
                }
                time = pushed
            }
            result[index].time = time
            previous = time
        }
        return result
    }

    // MARK: - Reporting

    private static func measure(
        document: ImportedChordDocument,
        placements: [Placement],
        matches: [Int: LyricMatch],
        grid: BeatGrid?,
        barOffset: Int,
        evidence: [BeatChordEvidence],
        duration: TimeInterval,
        chords: SongChords,
        reference: SongChords?,
        pitchOffset: Int
    ) -> ChordChartAlignment {
        let unknownChords = document.warnings.count { $0.kind == .unknownChord }
        let parseCoverage = Double(document.events.count)
            / Double(max(1, document.events.count + unknownChords))
        let lyricCoverage = document.lyricAnchors.isEmpty
            ? 0
            : Double(matches.count) / Double(document.lyricAnchors.count)
        let gridEvents = document.events.count {
            if case .grid = $0.location { return true }
            return false
        }
        let beatCoverage = gridEvents == 0 ? 0 : Double(
            document.events.count { gridTime($0.location, grid: grid, barOffset: barOffset) != nil }
        ) / Double(gridEvents)

        let audioScores: [Double] = evidence.isEmpty ? [] : placements.indices.map { index in
            let beat = nearestBeat(to: placements[index].time, in: evidence)
            return evidence[beat].agreement(with: document.events[index].chord)
        }
        let audioAgreement = audioScores.isEmpty
            ? nil
            : audioScores.reduce(0, +) / Double(audioScores.count)

        let estimated = placements.contains(where: \.isEstimated)
        var warnings = document.warnings
        if estimated {
            warnings.append(.init(
                kind: .estimatedPlacement,
                message: "Some chord positions were estimated between the ones Atarang could anchor to a word, a bar, or the recording."
            ))
        }
        var durationMismatch = false
        if let sourceDuration = document.metadata.duration, sourceDuration > 0 {
            durationMismatch = abs(sourceDuration - duration) / duration > 0.2
        }
        if durationMismatch {
            warnings.append(.init(
                kind: .arrangementMismatch,
                message: "The chart's own duration differs substantially from this recording."
            ))
        }
        // A chart with plenty of words, almost none of which appear in this
        // song, is usually a chart for a different song or a different version
        // of it — not a chart that merely aligned badly.
        let anchorFamine = document.lyricAnchors.count >= 8 && lyricCoverage < 0.35
        if anchorFamine {
            warnings.append(.init(
                kind: .arrangementMismatch,
                message: "Few of the chart's lines matched this song's lyrics. Check that the chart is for this recording."
            ))
        }
        if let audioAgreement, audioAgreement < 0.3 {
            warnings.append(.init(
                kind: .audioDisagreement,
                message: "Many supplied chords disagree strongly with the recording. Their labels were preserved."
            ))
        }
        let comparison = pitchComparison(chords, reference: reference, duration: duration)
        var suggestedOffset: Int?
        if let comparison, comparison.best != 0,
           comparison.bestScore >= 0.35,
           comparison.bestScore > comparison.currentScore + 0.15 {
            suggestedOffset = pitchOffset + comparison.best
            let direction = comparison.best < 0 ? "above" : "below"
            let count = abs(comparison.best)
            warnings.append(.init(
                kind: .pitchMismatch,
                message: "This chart reads \(count) semitone\(count == 1 ? "" : "s") \(direction) this recording — a tuned-down guitar or a capo the transcriber assumed. The chords are placed correctly; only their pitch differs."
            ))
        }

        let placementConfidence = placements.map(\.confidence).reduce(0, +)
            / Double(max(1, placements.count))
        return ChordChartAlignment(
            parseCoverage: parseCoverage,
            lyricAnchorCoverage: lyricCoverage,
            beatCoverage: beatCoverage,
            audioAgreement: audioAgreement,
            confidence: audioAgreement.map { placementConfidence * 0.75 + $0 * 0.25 }
                ?? placementConfidence,
            usedEstimatedPlacements: estimated,
            likelyArrangementMismatch: durationMismatch || anchorFamine
                || (audioAgreement.map { $0 < 0.2 } ?? false),
            warnings: warnings,
            appliedPitchOffset: pitchOffset,
            suggestedPitchOffset: suggestedOffset,
            pitchAgreement: comparison?.currentScore
        )
    }

    /// Binary search: the beat list is sorted, and scanning it once per chord
    /// made this quadratic in the length of the song.
    private static func nearestBeat(
        to time: TimeInterval,
        in evidence: [BeatChordEvidence]
    ) -> Int {
        var low = 0
        var high = evidence.count - 1
        while low < high {
            let middle = (low + high) / 2
            if evidence[middle].start < time { low = middle + 1 } else { high = middle }
        }
        if low > 0, abs(evidence[low - 1].start - time) <= abs(evidence[low].start - time) {
            return low - 1
        }
        return low
    }

    // MARK: - Words

    private static func wordSpans(
        _ text: String
    ) -> [(column: Int, length: Int, normalized: String)] {
        var result: [(Int, Int, String)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            result.append((
                text.distance(from: text.startIndex, to: start),
                text.distance(from: start, to: index),
                normalized(String(text[start..<index]))
            ))
        }
        return result
    }

    /// Which word a chord printed at this column belongs to.
    ///
    /// Inside a word, that word — a chord over the middle of a word changes on
    /// that syllable. In the gap between two words, the word that follows:
    /// writers line a chord's first letter up with the syllable where it
    /// starts, and a column landing in whitespace is one that fell slightly
    /// short of it. Choosing the word before would put the change a whole word
    /// early.
    private static func wordIndex(
        at column: Int,
        in words: [(column: Int, length: Int, normalized: String)]
    ) -> Int {
        guard !words.isEmpty else { return 0 }
        if let inside = words.firstIndex(where: {
            column >= $0.column && column < $0.column + $0.length
        }) {
            return inside
        }
        return words.firstIndex { $0.column > column } ?? words.count - 1
    }

    /// For matching only, never for display.
    private static func normalized(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private static func words(_ source: String) -> Set<String> {
        Set(wordSpans(source).map(\.normalized).filter { !$0.isEmpty })
    }

    private static func similarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }
}

enum ChordProExporter {
    static func text(for chart: UserChordChart) -> String {
        var lines: [String] = []
        if let title = chart.sourceMetadata.title { lines.append("{title: \(title)}") }
        if let artist = chart.sourceMetadata.artist { lines.append("{artist: \(artist)}") }
        if let key = chart.sourceMetadata.key {
            lines.append("{key: \(PitchClass.name(key.tonic, preferringFlats: key.prefersFlats))\(key.isMinor ? "m" : "")}")
        }
        if chart.sourceMetadata.sourceCapo > 0 {
            lines.append("{capo: \(chart.sourceMetadata.sourceCapo)}")
        }
        for event in chart.document.events {
            lines.append("[\(event.printedSymbol)]")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
