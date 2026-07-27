import SwiftUI

/// The ways lyrics get into a song, and the ways they get corrected.
///
/// Each is a sheet of its own rather than a mode of one screen: pasting words,
/// timing them, and choosing between candidate matches are three different
/// jobs, and only one of them is ever in progress.
enum LyricsSheet: String, Identifiable {
    case paste
    case editor
    case captions
    case onlineLookup

    var id: String { rawValue }
}

struct LyricsSheetContent: View {
    let sheet: LyricsSheet
    let player: StemPlayer
    let store: LyricsStore

    var body: some View {
        switch sheet {
        case .paste: LyricsPasteSheet(store: store)
        case .editor: LyricsEditorSheet(player: player, store: store)
        case .captions: CaptionsImportSheet(store: store)
        case .onlineLookup: OnlineLyricsSheet(store: store)
        }
    }
}

// MARK: - Paste

/// Plain words, straight in. This is the path that makes the whole feature work
/// with no network: paste, then tap them into time.
struct LyricsPasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: LyricsStore

    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("One line per line. Put a section name in brackets — [Chorus] — and it becomes a marker you can turn into a saved section.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityLabel("Lyrics text")
            }
            .padding()
            .navigationTitle("Paste Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.replace(
                            with: SongLyrics(
                                source: .manual,
                                lines: LyricsFormat.parsePlainText(text)
                            )
                        )
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if text.isEmpty, let existing = store.lyrics {
                    text = existing.lines
                        .map { $0.sectionLabel.map { "[\($0)]" } ?? $0.text }
                        .joined(separator: "\n")
                }
            }
        }
    }
}

// MARK: - Editor

/// Correcting words and times, with the song playing behind the sheet.
struct LyricsEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let player: StemPlayer
    let store: LyricsStore

    @State private var offsetDraft: Double?

    private var lines: [LyricLine] { store.lyrics?.lines ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        TapTimestampView(player: player, store: store)
                    } label: {
                        Label("Tap to Timestamp", systemImage: "hand.tap")
                    }
                    .frame(minHeight: 44)
                } footer: {
                    Text("Play the song and tap Set as each line comes round. Timing a song by hand needs no network and no analysis.")
                }

                Section {
                    offsetSlider
                } header: {
                    Text("Global offset")
                } footer: {
                    Text("Shifts every line at once. Use it when the words are right but consistently early or late; nudge a single line below when only one is out.")
                }

                Section {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        LyricEditorRow(
                            line: line,
                            isUserEdited: line.isUserEdited,
                            time: line.start,
                            setFromPlayhead: {
                                store.update { $0.edit(index) { $0.start = player.currentPosition() } }
                                Haptics.boundarySet()
                            },
                            nudge: { delta in
                                store.update {
                                    $0.edit(index) { line in
                                        guard let start = line.start else { return }
                                        line.start = max(0, start + delta)
                                        line.words = line.words.map {
                                            LyricWord(text: $0.text, start: max(0, $0.start + delta))
                                        }
                                    }
                                }
                            },
                            commitText: { text in
                                store.update { $0.edit(index) { $0.text = text } }
                            },
                            seek: {
                                if let start = store.lyrics?.effectiveStart(atIndex: index) {
                                    player.seek(to: start)
                                }
                            }
                        )
                    }
                    .onDelete { offsets in
                        store.update { $0.lines.remove(atOffsets: offsets) }
                    }
                } header: {
                    Text("\(lines.count) lines")
                } footer: {
                    Text("A line you edit is marked as yours and is never overwritten by a later import or analysis.")
                }
            }
            .navigationTitle("Edit Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Committed when the drag ends rather than on every value: the slider
    /// passes through forty values on the way to the one the user wants, and
    /// each would otherwise be a file write.
    private var offsetSlider: some View {
        let current = offsetDraft ?? store.lyrics?.offset ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(offsetDescription(current))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Spacer()
                Button("Reset") {
                    offsetDraft = nil
                    store.update { $0.offset = 0 }
                }
                .buttonStyle(.bordered)
                .disabled(abs(current) < 0.005)
            }
            Slider(
                value: Binding(
                    get: { current },
                    set: { offsetDraft = ($0 * 20).rounded() / 20 }
                ),
                in: -2...2,
                onEditingChanged: { editing in
                    guard !editing, let value = offsetDraft else { return }
                    store.update { $0.offset = value }
                    offsetDraft = nil
                }
            )
            .accessibilityLabel("Lyrics offset")
            .accessibilityValue(offsetDescription(current))
        }
    }

    private func offsetDescription(_ value: Double) -> String {
        if abs(value) < 0.005 { return "In time with the song" }
        return value > 0
            ? String(format: "%.2f s later", value)
            : String(format: "%.2f s earlier", -value)
    }
}

/// One editable line.
///
/// The text is held locally and committed when the field is left, so typing a
/// word does not write the file forty times.
struct LyricEditorRow: View {
    let line: LyricLine
    let isUserEdited: Bool
    let time: TimeInterval?
    let setFromPlayhead: () -> Void
    let nudge: (TimeInterval) -> Void
    let commitText: (String) -> Void
    let seek: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        line: LyricLine,
        isUserEdited: Bool,
        time: TimeInterval?,
        setFromPlayhead: @escaping () -> Void,
        nudge: @escaping (TimeInterval) -> Void,
        commitText: @escaping (String) -> Void,
        seek: @escaping () -> Void
    ) {
        self.line = line
        self.isUserEdited = isUserEdited
        self.time = time
        self.setFromPlayhead = setFromPlayhead
        self.nudge = nudge
        self.commitText = commitText
        self.seek = seek
        _draft = State(initialValue: line.displayText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: time == nil ? setFromPlayhead : seek) {
                    Text(time.map(StudioFormat.preciseTime) ?? "Set")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(minWidth: 58, minHeight: 30)
                        .foregroundStyle(time == nil ? Color.secondary : .indigo)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(
                    time == nil
                        ? "Set this line's time from the playhead"
                        : "Jump to \(StudioFormat.preciseTime(time!))"
                )
                if line.isSection {
                    Text(line.sectionLabel ?? "")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.indigo)
                } else {
                    TextField("Line", text: $draft, axis: .vertical)
                        .focused($isFocused)
                        .onSubmit { commitIfChanged() }
                }
                Spacer(minLength: 0)
                if isUserEdited {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Edited by you")
                }
            }
            if time != nil {
                HStack(spacing: 10) {
                    Button { nudge(-0.1) } label: {
                        Label("Earlier", systemImage: "minus")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 32)
                    }
                    Button { nudge(0.1) } label: {
                        Label("Later", systemImage: "plus")
                            .labelStyle(.iconOnly)
                            .frame(width: 44, height: 32)
                    }
                    Button("Set Here", action: setFromPlayhead)
                        .font(.caption)
                        .frame(minHeight: 32)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: isFocused) { _, focused in
            if !focused { commitIfChanged() }
        }
    }

    private func commitIfChanged() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !line.isSection, trimmed != line.text else { return }
        commitText(trimmed)
    }
}

// MARK: - Tap to timestamp

/// Timing a song by hand: play it, and tap Set as each line arrives.
///
/// This is the floor the whole phase stands on. With no network, no captions,
/// and no model, a song can still be fully synced here.
struct TapTimestampView: View {
    let player: StemPlayer
    let store: LyricsStore

    @State private var cursor = 0

    private var lines: [LyricLine] { store.lyrics?.lines ?? [] }

    var body: some View {
        VStack(spacing: 16) {
            PlayheadView(player: player) { position in
                Text(StudioFormat.preciseTime(position))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Text(text(at: cursor - 1))
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Text(text(at: cursor))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(text(at: cursor + 1))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding()
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )

            Button(action: stamp) {
                Text(cursor < lines.count ? "Set" : "Done")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, minHeight: 76)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cursor >= lines.count)

            HStack(spacing: 12) {
                Button {
                    player.skipBackward()
                } label: {
                    Label("Back 5", systemImage: "gobackward.5")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                Button {
                    player.togglePlayback()
                } label: {
                    Label(
                        player.isPlaying ? "Pause" : "Play",
                        systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                Button(action: undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(cursor == 0)
            }
            .buttonStyle(.bordered)

            Text("\(min(cursor, lines.count)) of \(lines.count) lines timed in this pass. The song keeps playing; each tap stamps the line on screen and moves to the next.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Tap to Timestamp")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cursor = firstUntimedIndex }
    }

    private var firstUntimedIndex: Int {
        lines.firstIndex { $0.start == nil } ?? 0
    }

    private func text(at index: Int) -> String {
        guard lines.indices.contains(index) else { return " " }
        let line = lines[index]
        return line.sectionLabel.map { "[\($0)]" } ?? line.text
    }

    private func stamp() {
        guard cursor < lines.count else { return }
        let index = cursor
        let position = player.currentPosition()
        store.update { $0.edit(index) { $0.start = position } }
        Haptics.boundarySet()
        cursor += 1
    }

    private func undo() {
        cursor = max(0, cursor - 1)
        let index = cursor
        store.update { $0.edit(index) { $0.start = nil } }
    }
}

// MARK: - Captions

/// YouTube's own caption track, offered with a preview rather than applied.
///
/// Automatic captions are frequently wrong about both words and timing, and
/// replacing a user's lyrics with them unasked would be the app deciding it
/// knows better.
struct CaptionsImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: LyricsStore

    @State private var candidate: SongLyrics?
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let candidate {
                    LyricsPreviewList(
                        lyrics: candidate,
                        note: candidate.source.confidenceNote
                    )
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        if isLoading {
                            ProgressView("Fetching captions…")
                        } else {
                            Text(message ?? "Atarang can read this video's caption track and use it as a starting point. Captions are often approximate, so you will see them before anything is applied.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Fetch Captions", action: fetch)
                                .buttonStyle(.borderedProminent)
                                .frame(minHeight: 44)
                        }
                    }
                    .frame(maxWidth: 420)
                    .padding(24)
                }
            }
            .navigationTitle("YouTube Captions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use These") {
                        if let candidate { store.replace(with: candidate) }
                        dismiss()
                    }
                    .disabled(candidate == nil)
                }
            }
        }
    }

    private func fetch() {
        guard let url = store.captionSourceURL else { return }
        isLoading = true
        message = nil
        Task {
            defer { isLoading = false }
            do {
                let fetched = try await LyricsLookup.youTubeCaptions(
                    for: url,
                    title: store.song?.title ?? "Captions"
                )
                if let fetched {
                    candidate = fetched
                } else {
                    message = "This video has no caption track Atarang can read."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - Online lookup

/// LRCLIB, behind the preference that has to be on for anything to be sent.
struct OnlineLyricsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LyricsLookup.onlineLookupDefaultsKey) private var isEnabled = false
    let store: LyricsStore

    @State private var track = ""
    @State private var artist = ""
    @State private var matches: [OnlineLyricsMatch] = []
    @State private var selected: OnlineLyricsMatch?
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    LyricsPreviewList(
                        lyrics: selected.lyrics,
                        note: "\(selected.trackName) — \(selected.artistName). " +
                            (selected.isSynced
                                ? "Contributed with timings; check them against your version."
                                : "Words only. Time them with Tap to Timestamp.")
                    )
                } else {
                    searchForm
                }
            }
            .navigationTitle("Online Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(selected == nil ? "Cancel" : "Back") {
                        if selected == nil { dismiss() } else { selected = nil }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use These") {
                        if let selected { store.replace(with: selected.lyrics) }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
            .onAppear { if track.isEmpty { track = store.song?.title ?? "" } }
        }
    }

    @ViewBuilder
    private var searchForm: some View {
        Form {
            if !isEnabled {
                Section {
                    Toggle("Look up lyrics online", isOn: $isEnabled)
                } footer: {
                    Text(Self.disclosure)
                }
            } else {
                Section {
                    TextField("Song title", text: $track)
                    TextField("Artist (optional)", text: $artist)
                    Button(action: search) {
                        Label("Search LRCLIB", systemImage: "magnifyingglass")
                            .frame(minHeight: 44)
                    }
                    .disabled(track.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                } footer: {
                    Text(Self.disclosure)
                }
                if isSearching {
                    Section { ProgressView("Searching…") }
                }
                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
                if !matches.isEmpty {
                    Section("Matches") {
                        ForEach(matches) { match in
                            Button {
                                selected = match
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(match.trackName)
                                            .font(.subheadline.weight(.semibold))
                                        if match.isSynced {
                                            Label("Synced", systemImage: "clock")
                                                .font(.caption2)
                                                .foregroundStyle(.indigo)
                                        }
                                    }
                                    Text(match.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// Said in full at the point of use, not only in Settings. Anyone who turns
    /// this on from here should have read the same sentence.
    private static let disclosure = "Searching sends the song title, the artist if you enter one, and nothing else to lrclib.net. Nothing is sent while this is off, and it is off until you turn it on."

    private func search() {
        isSearching = true
        message = nil
        matches = []
        Task {
            defer { isSearching = false }
            do {
                matches = try await LyricsLookup.searchOnline(
                    track: track,
                    artist: artist,
                    duration: store.song?.duration ?? 0
                )
                if matches.isEmpty { message = "No matches. Try the artist name, or a shorter title." }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// What a candidate would put on screen, before it does.
struct LyricsPreviewList: View {
    let lyrics: SongLyrics
    let note: String?

    var body: some View {
        List {
            if let note {
                Section {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("\(lyrics.lines.count) lines · \(lyrics.timedLineCount) timed") {
                ForEach(lyrics.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(line.start.map(StudioFormat.time) ?? "—")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        Text(line.displayText)
                            .font(line.isSection ? .caption.weight(.bold) : .subheadline)
                            .foregroundStyle(line.isSection ? Color.indigo : .primary)
                    }
                }
            }
        }
    }
}
