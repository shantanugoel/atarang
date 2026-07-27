import SwiftUI
import UniformTypeIdentifiers

/// The Lyrics stage: the words, as a practice instrument rather than as
/// decoration.
///
/// Tapping a line seeks to it, holding one loops it, and dragging across
/// several sets A–B — the same three things the transport does, reachable from
/// the thing the singer is already looking at.
struct LyricsStage: View {
    let player: StemPlayer
    let store: LyricsStore
    /// The full-screen presentation drops the header and grows the type.
    var isSingAlong = false
    var openSingAlong: (() -> Void)?

    @State private var sheet: LyricsSheet?
    @State private var showsFileImporter = false
    @State private var sharePayload: SharePayload?

    var body: some View {
        VStack(spacing: 0) {
            if !isSingAlong { header }
            if store.hasLyrics {
                LyricsReader(
                    player: player,
                    store: store,
                    isSingAlong: isSingAlong
                )
            } else {
                LyricsEmptyState(store: store) { sheet = $0 }
            }
        }
        .background(LyricsPlayheadDriver(player: player, store: store))
        .sheet(item: $sheet) { sheet in
            LyricsSheetContent(sheet: sheet, player: player, store: store)
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(items: payload.items)
                .presentationDetents([.medium, .large])
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.lrcLyrics, .plainText, .text]
        ) { result in
            switch result {
            case .success(let url): store.importFile(at: url)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .alert(
            "Lyrics",
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

    // MARK: - Header

    /// The source badge and every action, in one row. The badge is the honesty
    /// requirement: words the app guessed say so until the user corrects them.
    private var header: some View {
        HStack(spacing: 8) {
            if let lyrics = store.lyrics {
                LyricsSourceBadge(lyrics: lyrics)
            }
            Spacer(minLength: 0)
            if store.hasLyrics, let openSingAlong {
                Button(action: openSingAlong) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Sing-along mode")
            }
            Menu {
                lyricsMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Lyrics actions")
        }
        .padding(.horizontal)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var lyricsMenu: some View {
        Button {
            sheet = .paste
        } label: {
            Label(store.hasLyrics ? "Replace by Pasting" : "Paste Lyrics", systemImage: "doc.on.clipboard")
        }
        Button {
            showsFileImporter = true
        } label: {
            Label("Import .lrc File", systemImage: "square.and.arrow.down")
        }
        if store.captionSourceURL != nil {
            Button {
                sheet = .captions
            } label: {
                Label("Use YouTube Captions", systemImage: "captions.bubble")
            }
        }
        Button {
            sheet = .onlineLookup
        } label: {
            Label("Search Online Lyrics", systemImage: "magnifyingglass")
        }
        if store.hasLyrics {
            Divider()
            Button {
                sheet = .editor
            } label: {
                Label("Edit and Time Lines", systemImage: "slider.horizontal.below.square.filled.and.square")
            }
            Button {
                do { sharePayload = SharePayload(items: [try store.exportFile()]) }
                catch { store.errorMessage = error.localizedDescription }
            } label: {
                Label("Export .lrc", systemImage: "square.and.arrow.up")
            }
            if labelledSectionCount > 0 {
                Button(action: saveSectionsFromLabels) {
                    Label(
                        "Save \(labelledSectionCount) Section\(labelledSectionCount == 1 ? "" : "s")",
                        systemImage: "bookmark"
                    )
                }
            }
            Divider()
            Button(role: .destructive) {
                store.clear()
            } label: {
                Label("Remove Lyrics", systemImage: "trash")
            }
        }
    }

    /// How many sections these lyrics describe.
    ///
    /// Deliberately answered from the lyrics alone. Anything this menu reads
    /// while it is open, it re-reads when that value changes — and both
    /// `player.duration` and `player.practiceSettings` are mutated ten times a
    /// second during playback, which rebuilt the open menu under the user's
    /// finger and swallowed the tap. Lyrics do not move while a song plays.
    private var labelledSectionCount: Int {
        store.lyrics?.lines.filter { $0.isSection && $0.start != nil }.count ?? 0
    }

    /// Reads the player at the moment of the tap rather than while the menu is
    /// being built, which is what keeps it out of the menu's dependencies.
    /// `addSavedSections` drops ranges that overlap something already saved, so
    /// tapping this twice is not a duplicate factory.
    private func saveSectionsFromLabels() {
        guard let lyrics = store.lyrics, player.duration > 0 else { return }
        player.addSavedSections(lyrics.practiceSections(duration: player.duration))
        Haptics.boundarySet()
    }
}

/// Turns the player's 10 Hz position into the two values the reader watches.
///
/// It is its own leaf view for the reason `PlayheadView` is: reading
/// `player.position` anywhere larger would re-evaluate that whole view ten
/// times a second. Line changes and a whole-second countdown are both far below
/// display rate, so nothing here needs `TimelineView`.
private struct LyricsPlayheadDriver: View {
    let player: StemPlayer
    let store: LyricsStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: player.position, initial: true) { _, position in
                store.updatePlayhead(position: position)
            }
            .onChange(of: store.lyrics?.updatedAt, initial: false) { _, _ in
                store.updatePlayhead(position: player.position)
            }
    }
}

/// Says where the words came from, and stops saying it once the user has been
/// through them.
struct LyricsSourceBadge: View {
    let lyrics: SongLyrics

    var body: some View {
        if lyrics.isProvisional {
            Label(lyrics.source.label, systemImage: "questionmark.circle")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 9)
                .frame(minHeight: 26)
                .background(Color.orange.opacity(0.16), in: Capsule())
                .foregroundStyle(.orange)
                .accessibilityLabel("Source: \(lyrics.source.label), not yet checked")
        } else {
            Text("\(lyrics.timedLineCount) of \(lyrics.lines.count) lines timed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Reader

/// The scrolling words.
///
/// Auto-scroll follows the playhead until the user scrolls themselves, at which
/// point it stops and offers to come back. Nothing yanks the page out from
/// under someone reading ahead.
struct LyricsReader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let player: StemPlayer
    let store: LyricsStore
    var isSingAlong = false

    @State private var isFollowing = true
    /// Held in gesture state rather than view state so a cancelled press — a
    /// tap that lingered, a call arriving mid-gesture — cannot leave a line
    /// highlighted with no gesture behind it. SwiftUI resets this for us.
    @GestureState private var selection: LineSelection?
    @State private var lineFrames: [Int: CGRect] = [:]

    private static let space = "lyricsContent"

    private var lines: [LyricLine] { store.lyrics?.lines ?? [] }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: isSingAlong ? 18 : 12) {
                        // Half a screen of padding at each end so the first and
                        // last lines can still sit in the centre slot.
                        Spacer(minLength: 120)
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            // The count sits above the line it counts into, as
                            // a row of its own. Floating it over the page put
                            // it on top of that very line on a small screen —
                            // and anything laid out over scrolling text will
                            // land on some of it eventually.
                            if let entry = store.playhead.vocalEntry,
                               entry.lineIndex == index {
                                VocalEntryCountdown(seconds: entry.seconds)
                            }
                            row(index: index, line: line)
                                .id(index)
                        }
                        Spacer(minLength: 180)
                    }
                    .padding(.horizontal, isSingAlong ? 28 : 20)
                }
                .coordinateSpace(name: Self.space)
                .scrollIndicators(.hidden)
                // Any scroll of their own means they are reading somewhere
                // else, and the page must stop moving under them.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12).onChanged { _ in isFollowing = false }
                )
                .onChange(of: store.playhead.lineIndex) { _, index in
                    guard isFollowing, let index else { return }
                    scroll(proxy, to: index)
                }
                .onChange(of: isFollowing) { _, following in
                    guard following, let index = store.playhead.lineIndex else { return }
                    scroll(proxy, to: index)
                }
            }
            .onPreferenceChange(LyricLineFramesKey.self) { lineFrames = $0 }
            // The gesture's own `updating` body is not main-actor isolated, so
            // the confirmation the user feels when the selection takes hold is
            // driven from the state it produces rather than from inside it.
            .onChange(of: selection?.range) { _, range in
                if range != nil { Haptics.boundarySet() }
            }

            VStack(spacing: 8) {
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
                    .transition(.opacity)
                }
            }
            .padding(.bottom, 10)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isFollowing)
        }
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

    // MARK: - Rows

    @ViewBuilder
    private func row(index: Int, line: LyricLine) -> some View {
        let distance = abs(index - (store.playhead.lineIndex ?? 0))
        LyricLineRow(
            line: line,
            lyrics: store.lyrics,
            index: index,
            player: player,
            isCurrent: store.playhead.lineIndex == index,
            isSelected: selection?.range.contains(index) ?? false,
            distance: distance,
            isSingAlong: isSingAlong
        )
        .contentShape(Rectangle())
        .onTapGesture { seek(to: index) }
        .gesture(selectionGesture(from: index))
        .background(frameReporter(index: index))
    }

    /// Row geometry, reported only while a selection is being dragged.
    ///
    /// Measuring all the time would mean every scrolled frame writing a new
    /// dictionary into state and re-evaluating the page. During a selection the
    /// list is not scrolling — the gesture owns the touch — so the frames are
    /// both needed and still.
    @ViewBuilder
    private func frameReporter(index: Int) -> some View {
        if selection != nil {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LyricLineFramesKey.self,
                    value: [index: proxy.frame(in: .named(Self.space))]
                )
            }
        }
    }

    private func seek(to index: Int) {
        guard let start = store.lyrics?.effectiveStart(atIndex: index) else { return }
        player.seek(to: start)
        isFollowing = true
    }

    /// Hold a line to loop it; keep holding and drag to extend the loop across
    /// several. One gesture, because they are the same intent at two sizes —
    /// and it is sequenced behind a long press so it cannot fight the scroll.
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
                    if let drag, let target = Self.line(atY: drag.location.y, in: lineFrames) {
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
                if let drag, let target = Self.line(atY: drag.location.y, in: lineFrames) {
                    committed.extend(to: target)
                }
                commit(committed.range)
            }
    }

    private static func line(atY y: CGFloat, in frames: [Int: CGRect]) -> Int? {
        frames.first { $0.value.minY <= y && y <= $0.value.maxY }?.key
            ?? frames.min { abs($0.value.midY - y) < abs($1.value.midY - y) }?.key
    }

    /// Sets A and B through exactly the calls the transport's A–B button makes,
    /// so a loop set from the words and a loop set by hand are the same loop
    /// rather than two implementations that agree most of the time.
    private func commit(_ selection: ClosedRange<Int>) {
        guard let lyrics = store.lyrics,
              let range = lyrics.range(
                from: selection.lowerBound,
                to: selection.upperBound,
                duration: player.duration
              ) else { return }
        player.setLoopBoundaryA(at: range.start)
        player.setLoopBoundaryB(at: range.end)
        player.setLoopEnabled(true)
        player.seek(to: range.start)
        isFollowing = true
        Haptics.boundarySet()
    }
}

/// A run of lines being selected: where the press started, and how far the
/// finger has taken it.
struct LineSelection: Equatable {
    let anchor: Int
    private(set) var range: ClosedRange<Int>

    init(anchor: Int) {
        self.anchor = anchor
        range = anchor...anchor
    }

    mutating func extend(to target: Int) {
        range = min(anchor, target)...max(anchor, target)
    }
}

private struct LyricLineFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One line. A leaf, so a line change redraws the two rows whose appearance
/// actually differs rather than rebuilding the page.
struct LyricLineRow: View {
    let line: LyricLine
    let lyrics: SongLyrics?
    let index: Int
    let player: StemPlayer
    let isCurrent: Bool
    let isSelected: Bool
    /// How far from the current line, which is what the fade is built from.
    let distance: Int
    var isSingAlong: Bool

    var body: some View {
        Group {
            if let label = line.sectionLabel {
                Text(label.uppercased())
                    .font(.caption.weight(.heavy))
                    .kerning(1.4)
                    .foregroundStyle(.indigo)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            } else if isCurrent, !line.words.isEmpty {
                SweepingLyricLine(
                    line: line,
                    lyrics: lyrics,
                    player: player,
                    font: currentFont
                )
            } else {
                Text(line.text)
                    .font(isCurrent ? currentFont : otherFont)
                    .fontWeight(isCurrent ? .bold : .regular)
                    .foregroundStyle(isCurrent ? Color.primary : .secondary)
                    .opacity(opacity)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, isCurrent ? 6 : 2)
        .background(
            isSelected
                ? Color.green.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.sectionLabel.map { "Section \($0)" } ?? line.text)
        .accessibilityValue(isCurrent ? "Now" : "")
        .accessibilityHint("Double tap to jump here. Touch and hold to loop this line.")
    }

    /// Two lines either side stay readable; anything further is context, not
    /// something to read.
    private var opacity: Double {
        switch distance {
        case 0: 1
        case 1: 0.72
        case 2: 0.45
        default: 0.22
        }
    }

    private var currentFont: Font { isSingAlong ? .largeTitle : .title2 }
    private var otherFont: Font { isSingAlong ? .title2 : .body }
}

/// The current line, filling in word by word.
///
/// Rendered as one `Text` with per-word colouring rather than a mask sweeping
/// across it: a lyric line wraps, and a geometric sweep would have to know
/// where every line break landed. Word granularity is what the timings
/// actually carry anyway.
struct SweepingLyricLine: View {
    let line: LyricLine
    let lyrics: SongLyrics?
    let player: StemPlayer
    let font: Font

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            Text(attributed(at: player.currentPosition()))
                .font(font)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel(line.text)
    }

    private func attributed(at time: TimeInterval) -> AttributedString {
        let offset = lyrics?.offset ?? 0
        var result = AttributedString()
        for (index, word) in line.words.enumerated() {
            var piece = AttributedString(index == 0 ? word.text : " " + word.text)
            let nextStart = index + 1 < line.words.count
                ? line.words[index + 1].start + offset
                : .infinity
            if time >= nextStart {
                piece.foregroundColor = .primary
            } else if time >= word.start + offset {
                piece.foregroundColor = .indigo
            } else {
                piece.foregroundColor = .secondary
            }
            result += piece
        }
        return result
    }
}

/// The count into a vocal entry after a long instrumental stretch.
///
/// Laid out in the list rather than floated over it, directly above the line it
/// is counting into. That fixes the collision it used to cause on a small
/// screen and is the better placement anyway: the number now points at the
/// words it belongs to instead of sitting in a corner and leaving the singer to
/// work out which line is meant.
struct VocalEntryCountdown: View {
    let seconds: Int

    var body: some View {
        Label("Sing in \(seconds)", systemImage: "music.mic")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(Color.indigo.opacity(0.16), in: Capsule())
            .foregroundStyle(.indigo)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            // A count is one thing said once, not four separate announcements
            // interrupting whatever VoiceOver is reading.
            .accessibilityHidden(seconds != Int(SongLyrics.vocalEntryGap))
            .accessibilityLabel("Next line in \(seconds) seconds")
            .transition(.opacity)
    }
}

// MARK: - Empty state

struct LyricsEmptyState: View {
    let store: LyricsStore
    let open: (LyricsSheet) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "text.quote")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No lyrics yet")
                    .font(.headline)
                Text("Paste the words, import an .lrc file, or look them up. Once they are timed, tapping a line jumps to it and holding one loops it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    open(.paste)
                } label: {
                    Label("Paste Lyrics", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                if store.captionSourceURL != nil {
                    Button {
                        open(.captions)
                    } label: {
                        Label("Use YouTube Captions", systemImage: "captions.bubble")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    open(.onlineLookup)
                } label: {
                    Label("Search Online Lyrics", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Text("Everything else is in the menu above, including importing a file you already have.")
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
}
