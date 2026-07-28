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

    var statusLabel: String {
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

    static func parse(
        _ source: String,
        key: MusicalKey? = nil,
        sourceCapo: Int = 0
    ) -> Result? {
        var token = source.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "♭", with: "b")
        while token.hasPrefix("(") && token.hasSuffix(")") {
            token = String(token.dropFirst().dropLast())
        }
        let upper = token.uppercased()
        if ["N.C.", "N.C", "NC", "NOCHORD"].contains(upper) { return .noChord }

        if let degree = degreeRoot(token, key: key) {
            token = degree.remainder
            return makeChord(root: degree.root, token: token, sourceCapo: sourceCapo)
        }
        guard let root = notePrefix(token) else { return nil }
        token.removeFirst(root.length)
        return makeChord(root: root.pitch, token: token, sourceCapo: sourceCapo)
    }

    private static func makeChord(root: Int, token: String, sourceCapo: Int) -> Result? {
        let pieces = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let suffix = pieces.first.map(String.init) ?? ""
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
    ) -> (root: Int, remainder: String)? {
        guard let key else { return nil }
        if let first = source.first, let number = first.wholeNumberValue, (1...7).contains(number) {
            var remainder = String(source.dropFirst())
            var alteration = 0
            if remainder.hasPrefix("b") { alteration = -1; remainder.removeFirst() }
            if remainder.hasPrefix("#") { alteration = 1; remainder.removeFirst() }
            return (
                PitchClass.normalized(key.scalePitchClasses[number - 1] + alteration),
                remainder
            )
        }
        let symbols = ["vii", "vi", "iv", "iii", "ii", "v", "i"]
        let lowered = source.lowercased()
        guard let symbol = symbols.first(where: { lowered.hasPrefix($0) }) else { return nil }
        let degree = ["i", "ii", "iii", "iv", "v", "vi", "vii"].firstIndex(of: symbol)!
        let root = key.scalePitchClasses[degree]
        var remainder = String(source.dropFirst(symbol.count))
        if remainder.isEmpty, source.first?.isLowercase == true { remainder = "m" }
        return (root, remainder)
    }
}

// MARK: - Text formats

enum UserChordParser {
    static let maximumCharacters = 500_000

    static func parse(_ source: String) -> ImportedChordDocument {
        let text = String(source.prefix(maximumCharacters))
            .replacingOccurrences(of: "\t", with: "    ")
        var document = ImportedChordDocument(originalText: text)
        var currentSection: String?
        var gridBar = 0
        let lines = text.components(separatedBy: .newlines)

        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if isTab(trimmed) {
                document.warnings.append(.init(
                    kind: .ignoredTab,
                    message: "Ignored a guitar tablature line.",
                    line: lineIndex + 1
                ))
                continue
            }

            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
                parseDirective(
                    String(trimmed.dropFirst().dropLast()),
                    line: lineIndex,
                    document: &document,
                    currentSection: &currentSection
                )
                continue
            }

            if let label = sectionLabel(trimmed) {
                currentSection = label
                document.sections.append(.init(name: label, firstEventIndex: document.events.count))
                continue
            }

            if trimmed.contains("[") && trimmed.contains("]") {
                parseInline(
                    rawLine,
                    line: lineIndex,
                    section: currentSection,
                    document: &document
                )
                continue
            }

            if trimmed.contains("|") {
                let before = document.events.count
                parseGrid(
                    trimmed,
                    startingBar: gridBar,
                    section: currentSection,
                    line: lineIndex,
                    document: &document
                )
                if document.events.count > before {
                    gridBar += max(1, trimmed.filter { $0 == "|" }.count - 1)
                    continue
                }
            }

            let tokens = chordTokens(in: rawLine, metadata: document.metadata)
            if tokens.count >= 2, tokens.count == meaningfulTokens(in: trimmed).count {
                let nextLyricIndex = nextLyricLine(after: lineIndex, lines: lines)
                for (ordinal, token) in tokens.enumerated() {
                    let location: ImportedChordLocation
                    if let nextLyricIndex {
                        location = .lyric(line: nextLyricIndex, character: token.column)
                    } else {
                        location = .ordinal(document.events.count + ordinal)
                    }
                    append(
                        token: token.text,
                        location: location,
                        section: currentSection,
                        line: lineIndex,
                        document: &document
                    )
                }
                continue
            }

            document.lyricAnchors.append(.init(
                lineIndex: lineIndex,
                text: rawLine,
                section: currentSection
            ))
        }
        return document
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
            if let capo = Int(value), (0...12).contains(capo) {
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
        document: inout ImportedChordDocument
    ) {
        guard let parsed = parsedChord(token, metadata: document.metadata) else {
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
            parseConfidence: 1,
            section: section
        ))
    }

    private static func parsedChord(
        _ token: String,
        metadata: ImportedChordMetadata
    ) -> (chord: Chord?, isNoChord: Bool)? {
        switch ChordSymbolParser.parse(
            token,
            key: metadata.key,
            sourceCapo: metadata.sourceCapo
        ) {
        case .chord(let chord): (chord, false)
        case .noChord: (nil, true)
        case nil: nil
        }
    }

    private static func chordTokens(
        in line: String,
        metadata: ImportedChordMetadata
    ) -> [(text: String, column: Int)] {
        var result: [(String, Int)] = []
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
            if parsedChord(token, metadata: metadata) != nil {
                result.append((token, line.distance(from: line.startIndex, to: start)))
            }
        }
        return result
    }

    private static func meaningfulTokens(in line: String) -> [String] {
        line.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            !["x2", "x3", "x4", "repeat", ":||", "||:"].contains($0.lowercased())
        }
    }

    private static func nextLyricLine(after index: Int, lines: [String]) -> Int? {
        guard index + 1 < lines.count else { return nil }
        let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard !next.isEmpty, !next.contains("|"), !isTab(next), sectionLabel(next) == nil else {
            return nil
        }
        return index + 1
    }

    private static func sectionLabel(_ source: String) -> String? {
        guard source.hasPrefix("["), source.hasSuffix("]"), !source.contains("][") else { return nil }
        let value = String(source.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, ChordSymbolParser.parse(value) == nil else { return nil }
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

enum UserChordAligner {
    struct Result: Sendable {
        var chords: SongChords
        var alignment: ChordChartAlignment
    }

    static func align(
        _ document: ImportedChordDocument,
        lyrics: SongLyrics?,
        grid: BeatGrid?,
        duration: TimeInterval,
        evidence: [BeatChordEvidence] = []
    ) -> Result? {
        guard !document.events.isEmpty, duration > 0 else { return nil }
        let lyricMatches = matchLyricLines(document.lyricAnchors, to: lyrics)
        let gridEvents = document.events.filter {
            if case .grid = $0.location { return true }
            return false
        }.count
        let audioPlacements = constrainedAudioPlacements(
            events: document.events,
            evidence: evidence
        )
        var placements: [(ImportedChordEvent, TimeInterval, Double, Bool)] = []

        for (index, event) in document.events.enumerated() {
            if let exact = lyricTime(event.location, matches: lyricMatches, lyrics: lyrics) {
                placements.append((event, exact.time, exact.confidence, exact.estimated))
                continue
            }
            if let gridTime = gridTime(event.location, grid: grid) {
                placements.append((event, gridTime, 0.9, false))
                continue
            }
            if let audioTime = audioPlacements[event.id] {
                placements.append((event, audioTime, 0.68, false))
                continue
            }
            let time = duration * Double(index) / Double(max(1, document.events.count))
            placements.append((event, time, 0.35, true))
        }

        placements.sort { $0.1 < $1.1 }
        var segments: [ChordSegment] = []
        for index in placements.indices {
            let start = max(0, min(duration, placements[index].1))
            let next = index + 1 < placements.count ? placements[index + 1].1 : duration
            let end = max(start + 0.01, min(duration, next))
            guard end > start else { continue }
            segments.append(.init(
                start: start,
                end: end,
                chord: placements[index].0.chord,
                confidence: placements[index].2
            ))
        }
        var chords = SongChords(
            segments: segments,
            key: document.metadata.key.map {
                $0.transposed(by: document.metadata.sourceCapo)
            },
            confidence: placements.map(\.2).reduce(0, +) / Double(max(1, placements.count))
        )
        chords.sanitize(duration: duration)

        let matchedLines = Set(lyricMatches.keys).count
        let lyricCoverage = document.lyricAnchors.isEmpty
            ? 0
            : Double(matchedLines) / Double(document.lyricAnchors.count)
        let beatCoverage = gridEvents == 0 ? 0 : Double(
            document.events.filter { gridTime($0.location, grid: grid) != nil }.count
        ) / Double(gridEvents)
        let estimated = placements.contains(where: \.3)
        let audioScores: [Double] = placements.compactMap { placement in
            guard let closest = evidence.min(by: {
                abs($0.start - placement.1) < abs($1.start - placement.1)
            }) else { return nil }
            return closest.agreement(with: placement.0.chord)
        }
        let audioAgreement = audioScores.isEmpty
            ? nil
            : audioScores.reduce(0, +) / Double(audioScores.count)
        let durationMismatch: Bool
        if let sourceDuration = document.metadata.duration, sourceDuration > 0 {
            durationMismatch = abs(sourceDuration - duration) / duration > 0.2
        } else {
            durationMismatch = false
        }
        var warnings = document.warnings
        if estimated {
            warnings.append(.init(
                kind: .estimatedPlacement,
                message: "Some chord positions were evenly estimated because no timed lyric or beat anchor was available."
            ))
        }
        if durationMismatch {
            warnings.append(.init(
                kind: .arrangementMismatch,
                message: "The chart duration differs substantially from this recording."
            ))
        }
        if let audioAgreement, audioAgreement < 0.3 {
            warnings.append(.init(
                kind: .audioDisagreement,
                message: "Many supplied chords disagree strongly with the recording. Their labels were preserved."
            ))
        }
        let likelyMismatch = durationMismatch || (audioAgreement.map { $0 < 0.2 } ?? false)
        return Result(
            chords: chords,
            alignment: ChordChartAlignment(
                parseCoverage: Double(document.events.count) / Double(max(1, document.events.count + document.warnings.filter { $0.kind == .unknownChord }.count)),
                lyricAnchorCoverage: lyricCoverage,
                beatCoverage: beatCoverage,
                audioAgreement: audioAgreement,
                confidence: audioAgreement.map { chords.confidence * 0.75 + $0 * 0.25 }
                    ?? chords.confidence,
                usedEstimatedPlacements: estimated,
                likelyArrangementMismatch: likelyMismatch,
                warnings: warnings
            )
        )
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

    private struct LyricMatch {
        var line: LyricLine
        var score: Double
    }

    private static func matchLyricLines(
        _ anchors: [ImportedLyricAnchor],
        to lyrics: SongLyrics?
    ) -> [Int: LyricMatch] {
        guard let lyrics else { return [:] }
        var result: [Int: LyricMatch] = [:]
        var searchStart = 0
        for anchor in anchors {
            let wanted = words(anchor.text)
            guard !wanted.isEmpty, searchStart < lyrics.lines.count else { continue }
            var best: (index: Int, score: Double)?
            for index in searchStart..<lyrics.lines.count where !lyrics.lines[index].isSection {
                let score = similarity(wanted, words(lyrics.lines[index].text))
                if score > (best?.score ?? 0) { best = (index, score) }
            }
            if let best, best.score >= 0.45 {
                result[anchor.lineIndex] = LyricMatch(line: lyrics.lines[best.index], score: best.score)
                searchStart = best.index + 1
            }
        }
        return result
    }

    private static func lyricTime(
        _ location: ImportedChordLocation,
        matches: [Int: LyricMatch],
        lyrics: SongLyrics?
    ) -> (time: TimeInterval, confidence: Double, estimated: Bool)? {
        guard case .lyric(let lineIndex, let character) = location,
              let match = matches[lineIndex],
              let lyrics else { return nil }
        let line = match.line
        if !line.words.isEmpty {
            let text = Array(line.text)
            var wordStarts: [Int] = []
            var inWord = false
            for index in text.indices {
                if !text[index].isWhitespace && !inWord { wordStarts.append(index) }
                inWord = !text[index].isWhitespace
            }
            let wordIndex = max(0, wordStarts.lastIndex(where: { $0 <= character }) ?? 0)
            if line.words.indices.contains(wordIndex) {
                return (line.words[wordIndex].start + lyrics.offset, 0.98 * match.score, false)
            }
        }
        guard let start = lyrics.effectiveStart(of: line) else { return nil }
        let end = line.end.map { $0 + lyrics.offset } ?? start + 3
        let fraction = min(1, max(0, Double(character) / Double(max(1, line.text.count))))
        return (start + (end - start) * fraction, 0.7 * match.score, true)
    }

    private static func gridTime(
        _ location: ImportedChordLocation,
        grid: BeatGrid?
    ) -> TimeInterval? {
        guard case .grid(let bar, let beat) = location,
              let grid, grid.isReliable else { return nil }
        let downbeats = grid.beats.indices.filter { grid.beats[$0].isDownbeat }
        guard downbeats.indices.contains(bar) else { return nil }
        let start = downbeats[bar]
        let index = start + Int(beat.rounded(.down))
        guard grid.beats.indices.contains(index) else { return nil }
        let base = grid.beats[index].time
        let fraction = beat - beat.rounded(.down)
        return base + fraction * (grid.secondsPerBeat ?? 0)
    }

    private static func words(_ source: String) -> Set<String> {
        Set(
            source.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
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
