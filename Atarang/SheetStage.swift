import SwiftUI

/// The Sheet stage: chords over the words, the way a songbook prints them.
///
/// The other two stages each answer half a question — the Chords stage says
/// what to play and the Lyrics stage says when — and this is the page a person
/// actually props up on a music stand. Which is also why it has a size control
/// and nothing else: it is read from an arm's length away, with both hands busy.
struct SheetStage: View {
    let player: StemPlayer
    let lyrics: LyricsStore
    let chords: ChordStore
    let beats: BeatGridStore

    @AppStorage("sheetTextScale") private var textScale = 1.0
    @State private var page: ChordSheet?

    private static let scaleRange = 0.8...1.8

    private var semitones: Int { Int(player.pitchSemitones.rounded()) }
    private var options: ChordDisplayOptions { player.practiceSettings.chordDisplayOptions }

    var body: some View {
        VStack(spacing: 8) {
            if let page, !page.isEmpty {
                header
                SheetChart(
                    player: player,
                    lyrics: lyrics,
                    sheet: page,
                    textScale: textScale
                )
            } else {
                SheetEmptyState(
                    player: player,
                    lyrics: lyrics,
                    chords: chords,
                    needsTiming: page?.needsTiming ?? false
                )
            }
        }
        .background(SheetPlayheadDriver(player: player, store: lyrics))
        .onChange(of: lyrics.lyrics?.updatedAt, initial: true) { _, _ in rebuild() }
        .onChange(of: chords.chords?.updatedAt) { _, _ in rebuild() }
        .onChange(of: chords.userCollection.selectedSource) { _, _ in rebuild() }
        .onChange(of: semitones) { _, _ in rebuild() }
        .onChange(of: options) { _, _ in rebuild() }
        .onChange(of: beats.grid) { _, _ in rebuild() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let page, page.hasEstimatedPlacements {
                Label("Some positions estimated", systemImage: "questionmark.circle")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Chord positions are estimated, because these lyrics have no word timings.")
            }
            if options.capo > 0 {
                Text("Capo \(options.capo)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(minHeight: 24)
                    .background(Color.indigo.opacity(0.16), in: Capsule())
                    .foregroundStyle(.indigo)
            }
            Spacer(minLength: 0)
            Button {
                textScale = max(Self.scaleRange.lowerBound, textScale - 0.15)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: 44, height: 44)
            }
            .disabled(textScale <= Self.scaleRange.lowerBound)
            .accessibilityLabel("Smaller text")
            Button {
                textScale = min(Self.scaleRange.upperBound, textScale + 0.15)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: 44, height: 44)
            }
            .disabled(textScale >= Self.scaleRange.upperBound)
            .accessibilityLabel("Larger text")
        }
        .padding(.horizontal)
    }

    /// Rebuilt from the two artifacts rather than stored, and through the same
    /// lens the Chords stage uses, so the sheet and the chart never disagree
    /// about what the user asked to see.
    private func rebuild() {
        guard let words = lyrics.lyrics, let stored = chords.chords else {
            page = nil
            return
        }
        let displayed = ChordPlayability.apply(
            options,
            to: stored.transposed(by: semitones),
            duration: player.duration,
            beatDuration: beats.grid?.secondsPerBeat
        ).chords
        page = ChordSheet.build(
            lyrics: words,
            chords: displayed,
            duration: player.duration
        )
    }
}

/// Keeps the lyric playhead current while the Sheet stage is the one on screen.
///
/// The Lyrics stage has a driver of its own, and only one stage is ever
/// visible; this is what stops the sheet's highlight from freezing when the
/// user swipes to it.
private struct SheetPlayheadDriver: View {
    let player: StemPlayer
    let store: LyricsStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: player.position, initial: true) { _, position in
                store.updatePlayhead(position: position)
            }
    }
}

// MARK: - The page

struct SheetChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: StemPlayer
    let lyrics: LyricsStore
    let sheet: ChordSheet
    let textScale: Double

    @State private var isFollowing = true

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14 * textScale) {
                        ForEach(sheet.lines) { line in
                            SheetLineRow(
                                line: line,
                                textScale: textScale,
                                isCurrent: lyrics.playhead.lineIndex == line.index
                            )
                            .id(line.index)
                            .contentShape(Rectangle())
                            .onTapGesture { seek(to: line) }
                        }
                        Spacer(minLength: 120)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                // Any scroll of their own means they are reading somewhere
                // else, and the page must stop moving under them. Same rule as
                // the lyrics reader, because it is the same reading.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12).onChanged { _ in isFollowing = false }
                )
                .onChange(of: lyrics.playhead.lineIndex) { _, index in
                    guard isFollowing, let index else { return }
                    scroll(proxy, to: index)
                }
                .onChange(of: isFollowing) { _, following in
                    guard following, let index = lyrics.playhead.lineIndex else { return }
                    scroll(proxy, to: index)
                }
            }

            if !isFollowing {
                Button {
                    isFollowing = true
                } label: {
                    Label("Back to playhead", systemImage: "arrow.down.to.line")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isFollowing)
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        if reduceMotion {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func seek(to line: SheetLine) {
        guard let start = line.leadingChords.first?.time ?? line.start else { return }
        player.seek(to: start)
        isFollowing = true
    }
}

/// One line of the page: the chords that came before it, then the words with
/// their own chords standing over them.
struct SheetLineRow: View {
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 19
    let line: SheetLine
    let textScale: Double
    let isCurrent: Bool

    private var lyricFont: Font {
        .system(size: baseSize * textScale, weight: isCurrent ? .semibold : .regular, design: .rounded)
    }

    private var chordFont: Font {
        .system(size: baseSize * textScale * 0.82, weight: .bold, design: .rounded)
            .monospacedDigit()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !line.leadingChords.isEmpty {
                HStack(spacing: 10) {
                    ForEach(line.leadingChords) { chord in
                        chordText(chord)
                    }
                }
                .padding(.bottom, 2)
            }
            if let label = line.sectionLabel {
                Text(label.uppercased())
                    .font(.caption.weight(.heavy))
                    .kerning(1.4)
                    .foregroundStyle(.indigo)
                    .padding(.top, 4)
            } else {
                SheetFlow(spacing: 0, lineSpacing: 6 * textScale) {
                    ForEach(line.chunks) { chunk in
                        VStack(alignment: .leading, spacing: 0) {
                            if let chord = chunk.chord {
                                chordText(chord)
                            } else {
                                // Keeps the words on one baseline whether or not
                                // this chunk has a chord over it.
                                chordText(nil).hidden()
                            }
                            Text(chunk.text)
                                .font(lyricFont)
                                .foregroundStyle(isCurrent ? Color.primary : .secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, isCurrent ? 4 : 0)
        .background(
            isCurrent ? Color.indigo.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(isCurrent ? "Now" : "")
        .accessibilityHint("Double tap to jump here.")
    }

    @ViewBuilder
    private func chordText(_ chord: SheetChord?) -> some View {
        Text(chord?.symbol ?? "—")
            .font(chordFont)
            .foregroundStyle(Color.indigo)
            .opacity(chord?.isExact == false ? 0.75 : 1)
            .overlay(alignment: .topTrailing) {
                if chord?.isSimplified == true {
                    Circle()
                        .strokeBorder(Color.indigo, lineWidth: 1)
                        .frame(width: 4, height: 4)
                        .offset(x: 5, y: 1)
                }
            }
            .padding(.trailing, 6)
    }

    private var spokenLabel: String {
        var parts: [String] = []
        if !line.leadingChords.isEmpty {
            parts.append("Before this line: " + line.leadingChords.map(\.spokenName).joined(separator: ", "))
        }
        if let label = line.sectionLabel {
            parts.append("Section \(label)")
        } else {
            parts.append(line.text)
            if !line.chords.isEmpty {
                parts.append("Chords: " + line.chords.map(\.spokenName).joined(separator: ", "))
            }
        }
        return parts.joined(separator: ". ")
    }
}

/// A left-aligned flow that wraps, so a long line of words with chords over
/// them breaks like text rather than running off the page.
///
/// `HStack` cannot do this and `Text` cannot carry a second baseline, which is
/// what a chord sheet is: two rows of type that have to stay in step
/// horizontally and wrap together.
struct SheetFlow: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, in: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item {
        let index: Int
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            // Measured against the row's own width, not unconstrained: a line
            // with one chord at its head is a single chunk, and at large text
            // sizes it has to wrap inside itself or it runs off the page.
            let size = subviews[index].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            let advance = current.items.isEmpty ? size.width : size.width + spacing
            if !current.items.isEmpty, current.width + advance > width {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(index: index, size: size))
            current.width += current.items.count == 1 ? size.width : advance
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Empty state

/// What is missing, and the one tap that fixes it.
struct SheetEmptyState: View {
    let player: StemPlayer
    let lyrics: LyricsStore
    let chords: ChordStore
    var needsTiming = false

    private var hasLyrics: Bool { lyrics.hasLyrics }
    private var hasChords: Bool { chords.hasChords }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Nothing to lay out yet")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !hasLyrics {
                    Button {
                        player.setStage(.lyrics)
                    } label: {
                        Label("Go to Lyrics", systemImage: "text.quote")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                } else if !hasChords {
                    Button {
                        player.setStage(.chords)
                    } label: {
                        Label("Go to Chords", systemImage: "guitars")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                } else if needsTiming {
                    Button {
                        player.setStage(.lyrics)
                    } label: {
                        Label("Time the Lines", systemImage: "timer")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("The sheet places each chord over the word it lands on — exactly where the lyrics carry word timings, and estimated across the line where they do not.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var detail: String {
        switch (hasLyrics, hasChords) {
        case (false, false):
            "A sheet is the words and the chords together, and this song has neither yet."
        case (false, true):
            "The chords are ready. Add the words and they will be laid out under them."
        case (true, false):
            "The words are here. Find the chords and they will be placed over them."
        case (true, true):
            needsTiming
                ? "These lyrics have no times yet, so there is nowhere to put a chord. Time the lines and the sheet builds itself."
                : "Nothing lined up between the words and the chords for this song."
        }
    }
}
