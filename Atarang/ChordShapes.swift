import Foundation

/// One way to play one chord on a guitar in standard tuning.
///
/// Fret numbers are absolute, one per string, low E first. `nil` is a string
/// that is not played; `0` is open. That is the same convention every chord box
/// in every songbook uses, so a shape read off this struct and a shape read off
/// paper are the same thing.
struct ChordShape: Equatable, Sendable, Identifiable {
    /// Six entries, low E to high e.
    var frets: [Int?]
    /// The fret the barre sits on, when there is one. Nothing here is a barre
    /// chord by accident: it is either recorded as one or it is not one.
    var barreFret: Int?
    /// How the chord is fingered in words, for VoiceOver — a chord box is a
    /// picture, and a picture read aloud is silence.
    var name: String

    var id: String { name }

    var isBarre: Bool { barreFret != nil }

    /// True when the shape uses only the first three frets and at least one
    /// open string. That is what "open position" means to the hand: no barre,
    /// no stretch, and the guitar doing some of the work.
    var isOpen: Bool {
        guard !isBarre else { return false }
        let played = frets.compactMap { $0 }
        guard played.contains(0) else { return false }
        return played.allSatisfy { $0 <= 3 }
    }

    /// The lowest fretted fret, which is where the hand has to be.
    var position: Int {
        frets.compactMap { $0 }.filter { $0 > 0 }.min() ?? 0
    }

    var stringCount: Int { frets.compactMap { $0 }.count }

    /// How hard this is to play, 0 easiest. Used to rank one voicing against
    /// another, and to score a capo — not to refuse anything.
    var difficulty: Double {
        var score: Double = isBarre ? 1 : 0
        score += Double(position) * 0.05
        return score
    }

    /// What VoiceOver says instead of describing a diagram it cannot see.
    var spokenFingering: String {
        let names = ["low E", "A", "D", "G", "B", "high E"]
        let parts = zip(names, frets).map { name, fret -> String in
            switch fret {
            case nil: "\(name) muted"
            case 0: "\(name) open"
            case let value?: "\(name) fret \(value)"
            }
        }
        let barre = barreFret.map { "Barre at fret \($0). " } ?? ""
        return barre + parts.joined(separator: ", ")
    }
}

/// Which shapes exist for which chords.
///
/// Deliberately a small, hand-written catalogue rather than a generated one. A
/// generator produces every mathematically valid voicing, most of which nobody
/// plays; what a person learning a song needs is the shape their teacher would
/// show them, and there are about thirty of those.
enum ChordShapes {
    // MARK: - Open shapes

    /// The open chords, keyed by root pitch class and quality.
    ///
    /// This list is also the definition of "playable in open position" that the
    /// Beginner level and the capo search are scored against, so adding to it
    /// changes both.
    static let open: [Chord: ChordShape] = {
        var table: [Chord: ChordShape] = [:]
        func add(_ root: Int, _ quality: ChordQuality, _ frets: [Int?], _ name: String) {
            table[Chord(root: root, quality: quality)] = ChordShape(
                frets: frets,
                barreFret: nil,
                name: name
            )
        }
        // Majors
        add(0, .major, [nil, 3, 2, 0, 1, 0], "C")
        add(2, .major, [nil, nil, 0, 2, 3, 2], "D")
        add(4, .major, [0, 2, 2, 1, 0, 0], "E")
        add(7, .major, [3, 2, 0, 0, 0, 3], "G")
        add(9, .major, [nil, 0, 2, 2, 2, 0], "A")
        // Minors
        add(2, .minor, [nil, nil, 0, 2, 3, 1], "Dm")
        add(4, .minor, [0, 2, 2, 0, 0, 0], "Em")
        add(9, .minor, [nil, 0, 2, 2, 1, 0], "Am")
        // Dominant sevenths
        add(0, .dominantSeventh, [nil, 3, 2, 3, 1, 0], "C7")
        add(2, .dominantSeventh, [nil, nil, 0, 2, 1, 2], "D7")
        add(4, .dominantSeventh, [0, 2, 0, 1, 0, 0], "E7")
        add(7, .dominantSeventh, [3, 2, 0, 0, 0, 1], "G7")
        add(9, .dominantSeventh, [nil, 0, 2, 0, 2, 0], "A7")
        add(11, .dominantSeventh, [nil, 2, 1, 2, 0, 2], "B7")
        // Minor sevenths
        add(2, .minorSeventh, [nil, nil, 0, 2, 1, 1], "Dm7")
        add(4, .minorSeventh, [0, 2, 2, 0, 3, 0], "Em7")
        add(9, .minorSeventh, [nil, 0, 2, 0, 1, 0], "Am7")
        // Major sevenths
        add(0, .majorSeventh, [nil, 3, 2, 0, 0, 0], "Cmaj7")
        add(2, .majorSeventh, [nil, nil, 0, 2, 2, 2], "Dmaj7")
        add(5, .majorSeventh, [nil, nil, 3, 2, 1, 0], "Fmaj7")
        add(9, .majorSeventh, [nil, 0, 2, 1, 2, 0], "Amaj7")
        // Suspended fourths
        add(2, .suspendedFourth, [nil, nil, 0, 2, 3, 3], "Dsus4")
        add(4, .suspendedFourth, [0, 2, 2, 2, 0, 0], "Esus4")
        add(9, .suspendedFourth, [nil, 0, 2, 2, 3, 0], "Asus4")
        // Power chords with an open root
        add(4, .power, [0, 2, 2, nil, nil, nil], "E5")
        add(9, .power, [nil, 0, 2, 2, nil, nil], "A5")
        add(2, .power, [nil, nil, 0, 2, 3, nil], "D5")
        return table
    }()

    /// The eight shapes a first month of guitar covers. Used only to rank one
    /// open-position answer above another — everything in `open` is playable.
    static let firstShapes: Set<Chord> = [
        Chord(root: 0, quality: .major),
        Chord(root: 2, quality: .major),
        Chord(root: 4, quality: .major),
        Chord(root: 7, quality: .major),
        Chord(root: 9, quality: .major),
        Chord(root: 2, quality: .minor),
        Chord(root: 4, quality: .minor),
        Chord(root: 9, quality: .minor)
    ]

    // MARK: - Movable shapes

    /// The E-shape and A-shape barre forms, as offsets from an open shape whose
    /// root is on the sixth or fifth string.
    private struct MovableForm {
        /// The open chord this form is a moved copy of.
        let openRoot: Int
        let frets: [Int?]
        /// Which string carries the root, named for the diagram's label.
        let rootString: String
    }

    private static let sixthStringForms: [ChordQuality: MovableForm] = [
        .major: MovableForm(openRoot: 4, frets: [0, 2, 2, 1, 0, 0], rootString: "6th string"),
        .minor: MovableForm(openRoot: 4, frets: [0, 2, 2, 0, 0, 0], rootString: "6th string"),
        .dominantSeventh: MovableForm(openRoot: 4, frets: [0, 2, 0, 1, 0, 0], rootString: "6th string"),
        .minorSeventh: MovableForm(openRoot: 4, frets: [0, 2, 0, 0, 0, 0], rootString: "6th string"),
        .majorSeventh: MovableForm(openRoot: 4, frets: [0, 2, 1, 1, 0, 0], rootString: "6th string"),
        .suspendedFourth: MovableForm(openRoot: 4, frets: [0, 2, 2, 2, 0, 0], rootString: "6th string"),
        .power: MovableForm(openRoot: 4, frets: [0, 2, 2, nil, nil, nil], rootString: "6th string")
    ]

    private static let fifthStringForms: [ChordQuality: MovableForm] = [
        .major: MovableForm(openRoot: 9, frets: [nil, 0, 2, 2, 2, 0], rootString: "5th string"),
        .minor: MovableForm(openRoot: 9, frets: [nil, 0, 2, 2, 1, 0], rootString: "5th string"),
        .dominantSeventh: MovableForm(openRoot: 9, frets: [nil, 0, 2, 0, 2, 0], rootString: "5th string"),
        .minorSeventh: MovableForm(openRoot: 9, frets: [nil, 0, 2, 0, 1, 0], rootString: "5th string"),
        .majorSeventh: MovableForm(openRoot: 9, frets: [nil, 0, 2, 1, 2, 0], rootString: "5th string"),
        .suspendedFourth: MovableForm(openRoot: 9, frets: [nil, 0, 2, 2, 3, 0], rootString: "5th string"),
        .diminished: MovableForm(openRoot: 9, frets: [nil, 0, 1, 2, 1, nil], rootString: "5th string"),
        .power: MovableForm(openRoot: 9, frets: [nil, 0, 2, 2, nil, nil], rootString: "5th string")
    ]

    /// Every shape this catalogue knows for a chord, easiest first.
    static func shapes(for chord: Chord) -> [ChordShape] {
        var result: [ChordShape] = []
        // The bass note is not part of the shape: a slash chord is the same
        // grip with a different note under it, and printing a separate box for
        // every inversion would bury the shape the hand actually makes.
        let plain = Chord(root: chord.root, quality: chord.quality)
        if let shape = open[plain] { result.append(shape) }
        for forms in [sixthStringForms, fifthStringForms] {
            guard let form = forms[plain.quality] else { continue }
            let offset = PitchClass.normalized(plain.root - form.openRoot)
            // A barre at the twelfth fret is nobody's answer; the other form
            // will be lower. Zero is the open shape, which is already above.
            guard offset > 0, offset <= 11 else { continue }
            let frets = form.frets.map { $0.map { $0 + offset } }
            result.append(
                ChordShape(
                    frets: frets,
                    barreFret: offset,
                    name: plain.symbol(preferringFlats: false) + " (\(form.rootString))"
                )
            )
        }
        return result.sorted { $0.difficulty < $1.difficulty }
    }

    /// The shape to show, or `nil` when this catalogue has nothing for the
    /// chord — a diminished seventh, say. Saying nothing is the honest answer;
    /// a made-up box is not.
    static func best(for chord: Chord) -> ChordShape? {
        shapes(for: chord).first
    }

    /// True when the chord has an open-position shape.
    static func isOpen(_ chord: Chord) -> Bool {
        open[Chord(root: chord.root, quality: chord.quality)] != nil
    }

    /// How easy a chord is to play, 1 easiest and 0 not playable from this
    /// catalogue at all. The number the capo search is built on.
    static func ease(of chord: Chord) -> Double {
        let plain = Chord(root: chord.root, quality: chord.quality)
        if firstShapes.contains(plain) { return 1 }
        if open[plain] != nil { return 0.85 }
        guard let shape = best(for: plain) else { return 0 }
        // A barre low on the neck is a chord most players can hold; the same
        // barre at the eighth fret is a different proposition.
        return max(0.1, 0.45 - Double(shape.position) * 0.02)
    }
}
