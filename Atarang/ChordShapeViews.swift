import SwiftUI

/// A chord box: six strings, five frets, and the dots that say where the
/// fingers go.
///
/// Drawn rather than shipped as images so it scales with Dynamic Type and works
/// in both appearances. It is an image to a sighted player and nothing at all to
/// VoiceOver, so the whole thing carries the spoken fingering as its label.
struct ChordDiagram: View {
    let shape: ChordShape
    /// The chord the shape sounds. With a capo fitted this is not what the
    /// shape is called, which is the whole point of saying both.
    var caption: String?
    var width: CGFloat = 96

    /// How many frets the box shows. Five covers every shape in the catalogue
    /// including a barre well up the neck.
    private static let fretCount = 5
    private static let stringCount = 6

    /// The fret the box starts at. Open shapes start at the nut; a barre chord
    /// at the fifth fret starts there and says so.
    private var firstFret: Int {
        let fretted = shape.frets.compactMap { $0 }.filter { $0 > 0 }
        guard let lowest = fretted.min(), lowest > 1 else { return 1 }
        return lowest
    }

    private var showsNut: Bool { firstFret == 1 }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                // The column is always there, empty or not: a row of boxes
                // whose grids do not line up because one of them starts at the
                // fifth fret reads as a mistake.
                Text(showsNut ? " " : "\(firstFret)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .trailing)
                    .padding(.top, width * 0.16)
                grid
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var grid: some View {
        Canvas { context, size in
            // The outer strings are inset by the width of a marker: a circle
            // drawn on the edge string would be half outside the box.
            let inset = min(4, size.width * 0.07)
            let spacing = (size.width - inset * 2) / CGFloat(Self.stringCount - 1)
            func stringX(_ index: Int) -> CGFloat { inset + CGFloat(index) * spacing }
            // Room for the open and muted marks above the nut, sized with the
            // box rather than fixed: at 54 points a fixed 10 clipped them.
            let top = size.height * 0.16
            let fretSpacing = (size.height - top) / CGFloat(Self.fretCount)
            let line = Color.secondary.opacity(0.55)

            for string in 0..<Self.stringCount {
                let x = stringX(string)
                var path = Path()
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(line), lineWidth: 1)
            }
            for fret in 0...Self.fretCount {
                let y = top + CGFloat(fret) * fretSpacing
                var path = Path()
                path.move(to: CGPoint(x: stringX(0), y: y))
                path.addLine(to: CGPoint(x: stringX(Self.stringCount - 1), y: y))
                context.stroke(
                    path,
                    with: .color(line),
                    lineWidth: fret == 0 && showsNut ? 3 : 1
                )
            }

            for (index, fret) in shape.frets.enumerated() {
                let x = stringX(index)
                guard let fret else {
                    let arm = min(3, top * 0.3)
                    var cross = Path()
                    cross.move(to: CGPoint(x: x - arm, y: top / 2 - arm))
                    cross.addLine(to: CGPoint(x: x + arm, y: top / 2 + arm))
                    cross.move(to: CGPoint(x: x + arm, y: top / 2 - arm))
                    cross.addLine(to: CGPoint(x: x - arm, y: top / 2 + arm))
                    context.stroke(cross, with: .color(line), lineWidth: 1)
                    continue
                }
                guard fret > 0 else {
                    let radius = min(3, top * 0.3)
                    let circle = Path(
                        ellipseIn: CGRect(
                            x: x - radius,
                            y: top / 2 - radius,
                            width: radius * 2,
                            height: radius * 2
                        )
                    )
                    context.stroke(circle, with: .color(line), lineWidth: 1)
                    continue
                }
                let row = CGFloat(fret - firstFret)
                guard row >= 0, row < CGFloat(Self.fretCount) else { continue }
                let y = top + (row + 0.5) * fretSpacing
                let radius = min(spacing, fretSpacing) * 0.32
                let dot = Path(
                    ellipseIn: CGRect(
                        x: x - radius,
                        y: y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
                context.fill(dot, with: .color(.indigo))
            }

            // The barre, drawn as the bar it is rather than as separate dots:
            // one finger across the neck is one thing to see.
            if let barre = shape.barreFret {
                let row = CGFloat(barre - firstFret)
                guard row >= 0, row < CGFloat(Self.fretCount) else { return }
                let y = top + (row + 0.5) * fretSpacing
                let played = shape.frets.enumerated().compactMap { $0.element == barre ? $0.offset : nil }
                guard let first = played.min(), let last = played.max(), last > first else { return }
                var path = Path()
                path.move(to: CGPoint(x: stringX(first), y: y))
                path.addLine(to: CGPoint(x: stringX(last), y: y))
                context.stroke(
                    path,
                    with: .color(.indigo),
                    style: StrokeStyle(lineWidth: min(spacing, fretSpacing) * 0.5, lineCap: .round)
                )
            }
        }
        .frame(width: width, height: width * 1.25)
    }

    private var spokenLabel: String {
        var value = caption.map { "\($0). " } ?? ""
        value += shape.spokenFingering
        return value
    }
}

/// Every chord this song asks for, as shapes, in one strip.
///
/// The answer to "what do I need to know before I start?", which is a different
/// question from "what comes next?" and deserves its own place on the screen.
struct ChordVocabularyStrip: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let chords: SongChords
    /// What was heard, when the strip is showing simplifications of it.
    var options: ChordDisplayOptions = .none
    var limit = 10

    @State private var selected: Chord?

    private var vocabulary: [Chord] {
        Array(chords.vocabulary.prefix(limit))
    }

    /// A chord box is a picture of a hand position, so it grows with the text
    /// around it rather than staying a fixed 54 points while the labels double.
    private var boxWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 70 : 54
    }

    /// Stated rather than inferred: an unconstrained strip is squeezed by
    /// whatever is below it and shows half a chord box, which is worse than
    /// showing none.
    private var stripHeight: CGFloat {
        boxWidth * 1.25 + (dynamicTypeSize.isAccessibilitySize ? 40 : 24)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(headline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if options.capo > 0 {
                    Text("Capo \(options.capo)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 22)
                        .background(Color.indigo.opacity(0.15), in: Capsule())
                        .foregroundStyle(.indigo)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(vocabulary, id: \.self) { chord in
                        Button {
                            selected = chord
                        } label: {
                            VStack(spacing: 3) {
                                if let shape = ChordShapes.best(for: chord) {
                                    ChordDiagram(shape: shape, width: boxWidth)
                                } else {
                                    Image(systemName: "questionmark.square.dashed")
                                        .font(.title3)
                                        .foregroundStyle(.tertiary)
                                        .frame(width: boxWidth, height: boxWidth * 1.25)
                                }
                                Text(chord.symbol(preferringFlats: chords.prefersFlats))
                                    .font(.caption.weight(.semibold))
                            }
                            .frame(minWidth: 56, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(chord.spokenName(preferringFlats: chords.prefersFlats)). \(ChordShapes.best(for: chord)?.spokenFingering ?? "No shape for this chord.")"
                        )
                        .accessibilityHint("Double tap for the full chord box.")
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: stripHeight)
            .scrollIndicators(.hidden)
        }
        .sheet(item: $selected) { chord in
            ChordShapeSheet(
                chord: chord,
                prefersFlats: chords.prefersFlats,
                capo: options.capo
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var headline: String {
        let count = chords.vocabulary.count
        let shown = vocabulary.count
        if count > shown { return "\(shown) of \(count) shapes in this song" }
        return "\(count) shape\(count == 1 ? "" : "s") in this song"
    }
}

/// One chord, every way this app knows to play it.
struct ChordShapeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chord: Chord
    let prefersFlats: Bool
    var capo = 0
    /// What was heard, when this chord is a simplification of it.
    var detected: Chord?

    private var shapes: [ChordShape] { ChordShapes.shapes(for: chord) }

    /// What the shape sounds like with the capo on, which is not what it is
    /// called. A player gripping a G shape at capo 2 is hearing A, and a chart
    /// that says only one of those is a chart that misleads somebody.
    private var sounding: Chord { chord.transposed(by: capo) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text(chord.symbol(preferringFlats: prefersFlats))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    if capo > 0 {
                        Text("With the capo at fret \(capo) this sounds \(sounding.symbol(preferringFlats: prefersFlats)).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let detected, detected != chord {
                        Label(
                            "Atarang heard \(detected.symbol(preferringFlats: prefersFlats)) here. This is the simpler shape.",
                            systemImage: "wand.and.stars"
                        )
                        .font(.caption)
                        .foregroundStyle(.indigo)
                        .multilineTextAlignment(.center)
                    }
                    if shapes.isEmpty {
                        Label(
                            "No shape for this one yet — it is outside the shapes Atarang carries.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    } else {
                        ForEach(shapes) { shape in
                            VStack(spacing: 6) {
                                ChordDiagram(shape: shape, width: 130)
                                Text(shape.isBarre ? "Barre at fret \(shape.barreFret ?? 0)" : "Open position")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                        }
                    }
                }
                .frame(maxWidth: 420)
                .padding()
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Chord Shape")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension Chord: Identifiable {
    /// Stable for the lifetime of the value, which is all a sheet needs: a
    /// chord *is* its root, quality, and bass.
    var id: String { "\(root)-\(quality.rawValue)-\(bass.map(String.init) ?? "")" }
}

// MARK: - Playability sheet

/// Everything about making the chart playable, in one place.
///
/// Complexity, the three toggles, the capo, and the key shift are one decision
/// with four handles — a player asking "can I play this?" tries them against
/// each other, so splitting them across four menus would mean four round trips
/// to answer one question.
struct ChordPlayabilitySheet: View {
    @Environment(\.dismiss) private var dismiss
    let player: StemPlayer
    /// The song's own chart, untransposed and unsimplified. Every suggestion is
    /// computed against it so the answers do not move when the display does.
    let chords: SongChords
    let unplayable: [Chord]

    private var settings: SongPracticeSettings { player.practiceSettings }

    private var capoSuggestion: ChordPlayability.CapoSuggestion? {
        ChordPlayability.bestCapo(for: chords)
    }

    private var keyShifts: [ChordPlayability.KeyShift] {
        Array(ChordPlayability.playableKeys(for: chords).prefix(4))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Level", selection: complexityBinding) {
                        ForEach(ChordComplexity.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.chordComplexity.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !unplayable.isEmpty {
                        Label(
                            unplayableMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("How much to show")
                } footer: {
                    Text("Simplified chords are marked, and the chord Atarang heard is always one tap away.")
                }

                Section("Tidying") {
                    Toggle(
                        "Hide slash chords",
                        isOn: Binding(
                            get: { settings.hidesChordInversions },
                            set: { player.setHidesChordInversions($0) }
                        )
                    )
                    Toggle(
                        "Merge repeated chords",
                        isOn: Binding(
                            get: { settings.mergesRepeatedChords },
                            set: { player.setMergesRepeatedChords($0) }
                        )
                    )
                    Toggle(
                        "Hide passing chords",
                        isOn: Binding(
                            get: { settings.hidesPassingChords },
                            set: { player.setHidesPassingChords($0) }
                        )
                    )
                }

                Section {
                    Stepper(
                        value: Binding(
                            get: { settings.capoFret },
                            set: { player.setCapoFret($0) }
                        ),
                        in: 0...ChordPlayability.maximumCapo
                    ) {
                        Text(settings.capoFret == 0 ? "No capo" : "Capo at fret \(settings.capoFret)")
                            .monospacedDigit()
                    }
                    if let capoSuggestion {
                        Button {
                            player.setCapoFret(capoSuggestion.fret)
                            Haptics.boundarySet()
                        } label: {
                            Label(capoSuggestion.summary, systemImage: "sparkles")
                                .frame(minHeight: 44)
                        }
                        .disabled(capoSuggestion.fret == settings.capoFret)
                    }
                } header: {
                    Text("Capo")
                } footer: {
                    Text("With a capo on, the chart prints the shape to grip rather than the chord it sounds.")
                }

                Section {
                    ForEach(keyShifts) { shift in
                        Button {
                            player.setPitchSemitones(Float(shift.semitones))
                            Haptics.boundarySet()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shift.title)
                                        .font(.subheadline.weight(.medium))
                                    Text("\(Int((shift.openShare * 100).rounded()))% open shapes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if Int(player.pitchSemitones.rounded()) == shift.semitones {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.indigo)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Shift the song instead")
                } footer: {
                    Text("Moves the audio itself, so the backing matches the easier chords. Nothing about the stored chart changes.")
                }
            }
            .navigationTitle("Playability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var complexityBinding: Binding<ChordComplexity> {
        Binding(
            get: { settings.chordComplexity },
            set: { player.setChordComplexity($0) }
        )
    }

    /// Named in the same terms the chart is printed in: with a capo on, the
    /// chord that has no open shape is the *shape*, not the chord it sounds.
    private var unplayableMessage: String {
        let capo = settings.capoFret
        let names = unplayable
            .prefix(4)
            .map { $0.transposed(by: -capo).symbol(preferringFlats: chords.prefersFlats) }
            .formatted(.list(type: .and))
        let verb = unplayable.count == 1 ? "has" : "have"
        let preamble = capo > 0 ? "With the capo at fret \(capo), " : ""
        return "\(preamble)\(names) \(verb) no open shape, so \(unplayable.count == 1 ? "it stays" : "they stay") a barre chord. A different capo may fix it."
    }
}
