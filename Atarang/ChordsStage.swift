import SwiftUI

/// How the chart is laid out. A preference about how someone reads chords
/// rather than a property of the song, so it is global and not per song.
enum ChordChartView: String, CaseIterable, Identifiable, Sendable {
    case bars
    case ribbon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: "Bars"
        case .ribbon: "Ribbon"
        }
    }

    var icon: String {
        switch self {
        case .bars: "square.grid.3x2"
        case .ribbon: "arrow.left.and.right"
        }
    }
}

/// The two values the chart watches, and nothing else.
///
/// Split from the store for the reason `LyricsPlayhead` is: the store holds
/// hundreds of segments that change only when the user corrects one, and this
/// holds two integers that change while the song plays. Keeping them apart is
/// what stops a bar change from invalidating the whole chart.
@MainActor
@Observable
final class ChordPlayhead {
    /// The segment the playhead is inside, as an index into the *displayed*
    /// chart.
    var segmentIndex: Int?
    var barIndex: Int?
    /// The next chord that differs from the one sounding, and how many beats
    /// away it is.
    var nextChord: Chord?
    var beatsToNextChord: Int?

    func clear() {
        segmentIndex = nil
        barIndex = nil
        nextChord = nil
        beatsToNextChord = nil
    }
}

/// The Chords stage: what to play, in time, in the key that is being heard.
struct ChordsStage: View {
    let player: StemPlayer
    let store: ChordStore
    let beats: BeatGridStore

    @AppStorage("chordChartView") private var chartView = ChordChartView.bars
    @State private var playhead = ChordPlayhead()
    /// The transposed chart, recomputed when the chords or the key change
    /// rather than on every redraw.
    @State private var displayed: SongChords?
    @State private var bars: [ChordBar] = []
    @State private var correcting: ChordSegment?

    private var semitones: Int { Int(player.pitchSemitones.rounded()) }

    private var job: AnalysisProgressCenter.Job? {
        AnalysisProgressCenter.shared.job(ofKind: .chordAnalysis)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let job, store.hasChords {
                ChordJobRow(job: job, stop: store.stopDetecting)
                    .padding(.horizontal)
            } else if store.hasChords {
                header
            }

            if let displayed, !displayed.isEmpty {
                ChordNowCard(
                    chords: displayed,
                    playhead: playhead,
                    isTransposed: semitones != 0
                )
                .padding(.horizontal)

                switch chartView {
                case .bars:
                    ChordBarGrid(
                        player: player,
                        chords: displayed,
                        bars: bars,
                        playhead: playhead,
                        sections: player.practiceSettings.savedSections,
                        correct: { correcting = $0 }
                    )
                case .ribbon:
                    ChordRibbon(player: player, chords: displayed)
                }
            } else {
                // The first analysis replaces the button with its own progress,
                // in the same place and inside the same explanation. A progress
                // bar pinned to the top of an otherwise empty screen says less
                // about what is happening, not more.
                ChordsEmptyState(
                    store: store,
                    beats: beats,
                    player: player,
                    job: job,
                    stop: store.stopDetecting,
                    analyze: analyze
                )
            }
        }
        .background(ChordPlayheadDriver(player: player, chords: displayed, playhead: playhead, bars: bars, grid: beats.grid))
        .onChange(of: store.chords?.updatedAt, initial: true) { _, _ in refresh() }
        .onChange(of: semitones) { _, _ in refresh() }
        .onChange(of: beats.grid) { _, _ in refresh() }
        .sheet(item: $correcting) { segment in
            ChordCorrectionSheet(
                segment: segment,
                prefersFlats: displayed?.prefersFlats ?? false
            ) { chord in
                store.correct(segment.id, to: chord, displayedSemitones: semitones)
            }
            .presentationDetents([.medium, .large])
        }
        .alert(
            "Chords",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func refresh() {
        let transposed = store.chords?.transposed(by: semitones)
        displayed = transposed
        if let transposed, let grid = beats.grid {
            bars = transposed.bars(using: grid, duration: player.duration)
        } else {
            bars = []
        }
    }

    /// One tap, whatever state the song is in. Chord analysis is
    /// beat-synchronous, so making the user run the beat detection first in the
    /// right order would be the app asking them to know its own pipeline.
    private func analyze() {
        if let grid = beats.grid, !grid.isEmpty {
            store.detect(using: grid)
        } else {
            beats.detect { grid in
                guard let grid, !grid.isEmpty else { return }
                store.detect(using: grid)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let displayed {
                ChordSourceBadge(chords: displayed, isTransposed: semitones != 0)
            }
            Spacer(minLength: 0)
            Picker("Chart", selection: $chartView) {
                ForEach(ChordChartView.allCases) { view in
                    Image(systemName: view.icon).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .accessibilityLabel("Chart layout")
            Menu {
                chordsMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Chord actions")
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var chordsMenu: some View {
        Button {
            analyze()
        } label: {
            Label("Analyse Again", systemImage: "arrow.clockwise")
        }
        .disabled(player.isRecording)
        if let displayed, !displayed.vocabulary.isEmpty {
            Section("This song uses") {
                Text(
                    displayed.vocabulary
                        .prefix(8)
                        .map { $0.symbol(preferringFlats: displayed.prefersFlats) }
                        .joined(separator: "  ")
                )
            }
        }
        Divider()
        Button(role: .destructive) {
            store.clear()
        } label: {
            Label("Remove Chords", systemImage: "trash")
        }
    }
}

/// Turns the player's 10 Hz position into the four values the chart watches.
///
/// Its own leaf view for the reason `PlayheadView` is: reading
/// `player.position` anywhere larger would re-evaluate the whole chart ten
/// times a second.
private struct ChordPlayheadDriver: View {
    let player: StemPlayer
    let chords: SongChords?
    let playhead: ChordPlayhead
    let bars: [ChordBar]
    let grid: BeatGrid?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: player.position, initial: true) { _, position in
                update(at: position)
            }
            .onChange(of: chords?.updatedAt, initial: false) { _, _ in
                update(at: player.position)
            }
    }

    private func update(at position: TimeInterval) {
        guard let chords, !chords.isEmpty else {
            playhead.clear()
            return
        }
        let index = chords.index(at: position)
        if playhead.segmentIndex != index { playhead.segmentIndex = index }

        let bar = bars.lastIndex { $0.start <= position }
        if playhead.barIndex != bar { playhead.barIndex = bar }

        let next = chords.nextChange(after: position)
        if playhead.nextChord != next?.chord { playhead.nextChord = next?.chord }
        // Counted in beats rather than seconds, because that is how a player
        // reads ahead: "two more beats" is actionable and "1.4 seconds" is not.
        let beatsAway = next.flatMap { segment -> Int? in
            guard let grid, grid.isReliable else { return nil }
            let count = grid.beats.filter { $0.time > position && $0.time <= segment.start }.count
            return count > 0 && count <= 8 ? count : nil
        }
        if playhead.beatsToNextChord != beatsAway { playhead.beatsToNextChord = beatsAway }
    }
}

// MARK: - Now card

/// What is sounding, and what is next.
struct ChordNowCard: View {
    let chords: SongChords
    let playhead: ChordPlayhead
    let isTransposed: Bool

    private var current: ChordSegment? {
        playhead.segmentIndex.flatMap { chords.segments.indices.contains($0) ? chords.segments[$0] : nil }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(current?.symbol(preferringFlats: chords.prefersFlats) ?? "—")
                // A text style rather than a point size: at accessibility sizes
                // a fixed 40 point chord ends up *smaller* than the "next"
                // chord beside it, which inverts the one hierarchy this card has.
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(
                    (current?.confidence ?? 1) < SongChords.confidentSegment
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color.primary)
                )
            Spacer(minLength: 0)
            if let next = playhead.nextChord {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Next")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(next.symbol(preferringFlats: chords.prefersFlats))
                        .font(.title3.weight(.semibold))
                    if let beats = playhead.beatsToNextChord {
                        Text("in \(beats) beat\(beats == 1 ? "" : "s")")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var value = "Now: "
        value += current?.chord?.spokenName(preferringFlats: chords.prefersFlats) ?? "no chord"
        if let next = playhead.nextChord {
            value += ". Next: " + next.spokenName(preferringFlats: chords.prefersFlats)
            if let beats = playhead.beatsToNextChord {
                value += ", in \(beats) beat\(beats == 1 ? "" : "s")"
            }
        }
        if isTransposed { value += ". Transposed to match what you are hearing." }
        return value
    }
}

/// Says where the chart came from, and how much of it to trust.
struct ChordSourceBadge: View {
    let chords: SongChords
    let isTransposed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                if !chords.isReliable {
                    Label("Uncertain", systemImage: "questionmark.circle")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(minHeight: 24)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
                if let key = chords.key {
                    Text(key.name)
                        .font(.caption.weight(.semibold))
                }
                if isTransposed {
                    Text("as heard")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                }
            }
            if chords.templatesStruggled {
                Text("Some of this song is more than these chord shapes can say.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Bar grid

/// The chart as bars, four to a row.
///
/// Tapping a bar seeks to it; holding one opens its chord for correction, and
/// keeping hold and dragging across several sets a bar-snapped loop. Those last
/// two are one gesture on purpose — it is the same gesture the lyrics use, and a
/// separate context menu on the same cell would fight it.
struct ChordBarGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: StemPlayer
    let chords: SongChords
    let bars: [ChordBar]
    let playhead: ChordPlayhead
    /// The song's saved sections, drawn as labels over the rows they start in.
    let sections: [SavedPracticeSection]
    let correct: (ChordSegment) -> Void

    @GestureState private var selection: LineSelection?
    @State private var barFrames: [Int: CGRect] = [:]

    private static let space = "chordChart"
    private static let barsPerRow = 4

    /// Rows of four bars, with a saved section's name above the row it starts
    /// in. Section labels come from the practice sections the song already has —
    /// the ones the lyrics can populate in one tap — rather than from a second
    /// idea of what a section is.
    private enum ChartRow: Identifiable {
        case section(String)
        case bars([ChordBar])

        var id: String {
            switch self {
            case .section(let name): "section-\(name)"
            case .bars(let bars): "bars-\(bars.first?.id ?? -1)"
            }
        }
    }

    private var rows: [ChartRow] {
        var result: [ChartRow] = []
        var remainingSections = sections
        for start in stride(from: 0, to: bars.count, by: Self.barsPerRow) {
            let chunk = Array(bars[start..<min(start + Self.barsPerRow, bars.count)])
            guard let first = chunk.first, let last = chunk.last else { continue }
            while let section = remainingSections.first, section.start < last.end {
                remainingSections.removeFirst()
                // A section that began before this row already has its label.
                if section.start >= first.start || start == 0 {
                    result.append(.section(section.name))
                }
            }
            result.append(.bars(chunk))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        switch row {
                        case .section(let name):
                            Text(name.uppercased())
                                .font(.caption2.weight(.heavy))
                                .kerning(1.2)
                                .foregroundStyle(.indigo)
                                .padding(.top, 6)
                        case .bars(let chunk):
                            HStack(spacing: 6) {
                                ForEach(chunk) { bar in
                                    barCell(bar).id(bar.id)
                                }
                                // Keeps the last row's bars the same width as
                                // every other row's rather than stretching two
                                // bars across the screen.
                                if chunk.count < Self.barsPerRow {
                                    ForEach(0..<(Self.barsPerRow - chunk.count), id: \.self) { _ in
                                        Color.clear.frame(maxWidth: .infinity, minHeight: 1)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            .coordinateSpace(name: Self.space)
            .scrollIndicators(.hidden)
            .onChange(of: playhead.barIndex) { _, index in
                guard let index, bars.indices.contains(index) else { return }
                // Centred rather than pinned to the top, which is what puts the
                // next row on screen before it is needed.
                if reduceMotion {
                    proxy.scrollTo(index, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
        .onPreferenceChange(ChordBarFramesKey.self) { barFrames = $0 }
        .onChange(of: selection?.range) { _, range in
            if range != nil { Haptics.boundarySet() }
        }
    }

    @ViewBuilder
    private func barCell(_ bar: ChordBar) -> some View {
        let isCurrent = playhead.barIndex == bar.id
        let isSelected = selection?.range.contains(bar.id) ?? false
        VStack(spacing: 2) {
            if bar.entries.isEmpty {
                Text("·")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(bar.entries) { entry in
                    Text(entry.chord?.symbol(preferringFlats: chords.prefersFlats) ?? "N.C.")
                        .font(
                            bar.entries.count > 2
                                ? .subheadline.weight(.semibold)
                                : .title3.weight(.bold)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        // Dimmed, not hidden. A chord the detector is unsure of
                        // is still the best answer available, and a hole in the
                        // chart leaves the player with nothing at all.
                        .opacity(entry.confidence < SongChords.confidentSegment ? 0.45 : 1)
                        .overlay(alignment: .topTrailing) {
                            if entry.isUserEdited {
                                Circle()
                                    .fill(Color.indigo)
                                    .frame(width: 4, height: 4)
                                    .offset(x: 6, y: 2)
                            }
                        }
                }
            }
            Text("\(bar.number)")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.vertical, 6)
        .background(
            isSelected
                ? AnyShapeStyle(Color.green.opacity(0.2))
                : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCurrent ? Color.indigo : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { player.seek(to: bar.start) }
        .gesture(selectionGesture(from: bar.id))
        .background(frameReporter(index: bar.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: bar))
        .accessibilityValue(isCurrent ? "Now" : "")
        .accessibilityHint("Double tap to jump here.")
        .accessibilityActions {
            if let entry = bar.entries.first, let segment = segment(for: entry.id) {
                Button("Correct this chord") { correct(segment) }
            }
            Button("Loop this bar") { setLoop(bar.id...bar.id) }
        }
    }

    private func label(for bar: ChordBar) -> String {
        let symbols = bar.entries
            .map { $0.chord?.spokenName(preferringFlats: chords.prefersFlats) ?? "no chord" }
            .joined(separator: ", ")
        return "Bar \(bar.number), \(symbols.isEmpty ? "empty" : symbols)"
    }

    /// Bar geometry, reported only while a selection is live — measuring all
    /// the time would mean every scrolled frame writing a new dictionary into
    /// state and re-evaluating the chart.
    @ViewBuilder
    private func frameReporter(index: Int) -> some View {
        if selection != nil {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ChordBarFramesKey.self,
                    value: [index: proxy.frame(in: .named(Self.space))]
                )
            }
        }
    }

    /// Hold a bar to work on it; keep holding and drag to take in more.
    ///
    /// Sequenced behind a long press so it cannot fight the scroll — the same
    /// arrangement the lyrics reader uses, and for the same reason.
    private func selectionGesture(from index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(
                before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            )
            .updating($selection) { value, state, _ in
                switch value {
                case .first(true):
                    if state == nil { state = LineSelection(anchor: index) }
                case .second(true, let drag):
                    var current = state ?? LineSelection(anchor: index)
                    if let drag, let target = Self.bar(at: drag.location, in: barFrames) {
                        current.extend(to: target)
                    }
                    state = current
                default:
                    break
                }
            }
            .onEnded { value in
                guard case .second(true, let drag) = value else { return }
                var committed = LineSelection(anchor: index)
                if let drag, let target = Self.bar(at: drag.location, in: barFrames) {
                    committed.extend(to: target)
                }
                // One bar and no movement is a request to fix that chord;
                // several bars is a request to loop them. The finger says which.
                if committed.range.count == 1,
                   let entry = bars.first(where: { $0.id == index })?.entries.first,
                   let segment = segment(for: entry.id) {
                    correct(segment)
                } else {
                    setLoop(committed.range)
                }
            }
    }

    private static func bar(at point: CGPoint, in frames: [Int: CGRect]) -> Int? {
        frames.first { $0.value.contains(point) }?.key
            ?? frames.min {
                hypot($0.value.midX - point.x, $0.value.midY - point.y)
                    < hypot($1.value.midX - point.x, $1.value.midY - point.y)
            }?.key
    }

    private func segment(for id: UUID) -> ChordSegment? {
        chords.segments.first { $0.id == id }
    }

    /// Sets A and B through the transport's own calls, so a loop set from the
    /// chart and one set by hand are the same loop.
    private func setLoop(_ range: ClosedRange<Int>) {
        guard let first = bars.first(where: { $0.id == range.lowerBound }),
              let last = bars.first(where: { $0.id == range.upperBound }) else { return }
        player.setLoopBoundaryA(at: first.start)
        player.setLoopBoundaryB(at: last.end)
        player.setLoopEnabled(true)
        player.seek(to: first.start)
        Haptics.boundarySet()
    }
}

private struct ChordBarFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Ribbon

/// The chart as a strip that scrolls under a fixed "now" line.
///
/// Driven by an offset at display rate rather than by a `ScrollView` scrolled
/// programmatically: the chords have to arrive at the line exactly when they are
/// played, and a scroll animation retargeted ten times a second reads as
/// stuttering. Only the segments inside the visible window are built, so a
/// nine-minute song costs the same as a two-minute one.
struct ChordRibbon: View {
    let player: StemPlayer
    let chords: SongChords

    /// How much of the song fits on screen. Wide enough to see the next couple
    /// of changes coming, narrow enough that the symbols stay large.
    private static let secondsOnScreen: Double = 12
    /// Where the now line sits, so most of the strip is what is *coming*.
    private static let nowFraction: CGFloat = 0.3

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let scale = width / Self.secondsOnScreen
            let nowX = width * Self.nowFraction

            PlayheadView(player: player) { position in
                ZStack(alignment: .topLeading) {
                    ForEach(visibleSegments(around: position)) { segment in
                        chip(segment, isCurrent: segment.start <= position && position < segment.end)
                            .frame(width: max(28, (segment.duration) * scale - 4), alignment: .leading)
                            .offset(x: (segment.start - position) * scale + nowX)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .clipped()
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.indigo)
                    .frame(width: 2)
                    .offset(x: nowX)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal)
        .padding(.bottom, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chord ribbon")
        .accessibilityHint("Switch to the bar chart to work on individual chords")
    }

    private func visibleSegments(around position: TimeInterval) -> [ChordSegment] {
        let start = position - Self.secondsOnScreen * Double(Self.nowFraction) - 2
        let end = position + Self.secondsOnScreen + 2
        return chords.segments.filter { $0.end > start && $0.start < end }
    }

    private func chip(_ segment: ChordSegment, isCurrent: Bool) -> some View {
        Text(segment.symbol(preferringFlats: chords.prefersFlats))
            .font(.title2.weight(isCurrent ? .bold : .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(
                isCurrent ? Color.indigo.opacity(0.16) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .opacity(segment.confidence < SongChords.confidentSegment ? 0.5 : 1)
    }
}

// MARK: - Job and empty state

struct ChordJobRow: View {
    let job: AnalysisProgressCenter.Job
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if job.isWaiting {
                ProgressView()
            } else {
                ProgressView(value: job.progress)
            }
            HStack {
                Text(job.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop", role: .cancel, action: stop)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
        }
    }
}

struct ChordsEmptyState: View {
    let store: ChordStore
    let beats: BeatGridStore
    let player: StemPlayer
    /// The analysis this screen started, while it is still running.
    var job: AnalysisProgressCenter.Job?
    var stop: () -> Void = {}
    let analyze: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "guitars")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No chords yet")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let job {
                    ChordJobRow(job: job, stop: stop)
                } else if store.harmonicStems.isEmpty {
                    Label(
                        "This separation has no stem to take chords from.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Button(action: analyze) {
                        Label(
                            beats.hasGrid ? "Find the Chords" : "Find the Beat and Chords",
                            systemImage: "waveform.and.magnifyingglass"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(player.isRecording)
                }
                if let notice = store.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text(footer)
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
        let stems = store.harmonicStems
        guard !stems.isEmpty else {
            return "Chords are read from the bass and the backing instruments, and this separation has neither."
        }
        let names = stems.map { $0.title.lowercased() }.formatted(.list(type: .and))
        return "Atarang listens to the \(names) and works out the chords, bar by bar. Nothing is downloaded and nothing leaves this device."
    }

    private var footer: String {
        "Chords are worked out from a beat grid, so the beat is found first if it has not been already. Anything wrong can be corrected by holding the bar it is in, and your corrections survive running this again."
    }
}

// MARK: - Correction

/// One chord, corrected by the person who can hear it.
struct ChordCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let segment: ChordSegment
    let prefersFlats: Bool
    let apply: (Chord?) -> Void

    @State private var root: Int
    @State private var quality: ChordQuality
    @State private var isNoChord: Bool

    init(
        segment: ChordSegment,
        prefersFlats: Bool,
        apply: @escaping (Chord?) -> Void
    ) {
        self.segment = segment
        self.prefersFlats = prefersFlats
        self.apply = apply
        _root = State(initialValue: segment.chord?.root ?? 0)
        _quality = State(initialValue: segment.chord?.quality ?? .major)
        _isNoChord = State(initialValue: segment.chord == nil)
    }

    private static let rootColumns = [GridItem](
        repeating: GridItem(.flexible(), spacing: 6),
        count: 4
    )

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(preview)
                            .font(.system(.title, design: .rounded).weight(.bold))
                        Spacer()
                        Text("\(StudioFormat.time(segment.start)) – \(StudioFormat.time(segment.end))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(detectedDescription)
                }

                Section {
                    Toggle("No chord here", isOn: $isNoChord)
                }

                if !isNoChord {
                    Section("Root") {
                        LazyVGrid(columns: Self.rootColumns, spacing: 6) {
                            ForEach(0..<12, id: \.self) { pitch in
                                Button {
                                    root = pitch
                                } label: {
                                    Text(PitchClass.name(pitch, preferringFlats: prefersFlats))
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.bordered)
                                .tint(root == pitch ? .indigo : .secondary)
                            }
                        }
                    }
                    Section("Quality") {
                        Picker("Quality", selection: $quality) {
                            ForEach(ChordQuality.allCases, id: \.self) { value in
                                Text(value == .major ? "major" : value.spokenName).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .navigationTitle("Correct Chord")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        apply(isNoChord ? nil : Chord(root: root, quality: quality))
                        Haptics.boundarySet()
                        dismiss()
                    }
                }
            }
        }
    }

    private var preview: String {
        isNoChord ? "N.C." : Chord(root: root, quality: quality).symbol(preferringFlats: prefersFlats)
    }

    private var detectedDescription: String {
        if segment.isUserEdited { return "You set this one." }
        let symbol = segment.symbol(preferringFlats: prefersFlats)
        let certainty = segment.confidence < SongChords.confidentSegment
            ? "and was not confident about it"
            : "and was fairly confident"
        return "Atarang heard \(symbol) \(certainty). Saving keeps your answer through any later analysis."
    }
}
