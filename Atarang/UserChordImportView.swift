import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let chordPro = UTType(
        importedAs: "org.chordpro.text",
        conformingTo: .plainText
    )
}

struct UserChordImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ChordStore
    let lyrics: LyricsStore
    let beats: BeatGridStore
    let origin: UserChordOrigin

    @State private var text: String
    @State private var document: ImportedChordDocument
    @State private var chartName: String
    @State private var updateChartID: UUID?
    /// The alignment shown in the preview, and the one `Add Chart` uses.
    ///
    /// Held rather than recomputed inside `body`: aligning a chart is a
    /// dynamic program over every chord and every beat, and running it during
    /// view evaluation meant running it again on every keystroke.
    @State private var alignedPreview: UserChordAligner.Result?
    @State private var isAligning = false
    @State private var alignmentTask: Task<Void, Never>?
    /// Semitones the user has chosen to move the chart by, if any.
    @State private var pitchOffset = 0

    init(
        store: ChordStore,
        lyrics: LyricsStore,
        beats: BeatGridStore,
        origin: UserChordOrigin,
        text: String = ""
    ) {
        self.store = store
        self.lyrics = lyrics
        self.beats = beats
        self.origin = origin
        _text = State(initialValue: text)
        let parsed = UserChordParser.parse(text)
        _document = State(initialValue: parsed)
        _chartName = State(initialValue: parsed.metadata.title ?? "My chart")
    }

    var body: some View {
        NavigationStack {
            Form {
                disclosure
                input
                if !text.isEmpty {
                    preview
                    warnings
                }
            }
            .navigationTitle("Import Chord Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Chart", action: add)
                        .disabled(document.events.isEmpty)
                }
            }
            .onChange(of: text, initial: true) { _, value in
                document = UserChordParser.parse(value)
                if chartName == "My chart", let title = document.metadata.title {
                    chartName = title
                }
                realign()
            }
            .onDisappear { alignmentTask?.cancel() }
        }
    }

    private var disclosure: some View {
        Section {
            Label("Processed entirely on this device", systemImage: "iphone.and.arrow.forward")
                .foregroundStyle(.green)
            Text("Import a chart you created or are allowed to use. Atarang reads and aligns it on this device; it does not contact the chart’s source.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Said before the import rather than after it goes wrong. Lining a
            // chart up against a recording is guesswork wherever the words run
            // out, and a chart written for another take or another tuning is
            // not a mistake anyone can see from the text alone.
            Label("Expect to correct a few things", systemImage: "hand.raised")
                .foregroundStyle(.orange)
            Text("Atarang lines the chart up against this recording as well as it can, using the words, the bars and the audio. It will not get everything right — instrumental sections and charts written for a different take drift the most. The chords stay exactly as you supplied them, and you can fix any of them by tapping it on the Chords stage.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var input: some View {
        Section("Chart text") {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .accessibilityLabel("Chord chart text")
            if text.count >= UserChordParser.maximumCharacters {
                Label("The import was limited to 500,000 characters.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var preview: some View {
        Section("Preview") {
            TextField("Chart name", text: $chartName)
            LabeledContent("Chords", value: "\(document.chordCount)")
            LabeledContent("Sections", value: "\(document.sections.count)")
            if !store.userCollection.charts.isEmpty {
                Picker("When added", selection: $updateChartID) {
                    Text("Add as another chart").tag(nil as UUID?)
                    ForEach(store.userCollection.charts) { chart in
                        Text("Update \(chart.name)").tag(chart.id as UUID?)
                    }
                }
            }
            if let key = document.metadata.key {
                LabeledContent("Source key", value: key.name)
            }
            if document.metadata.sourceCapo > 0 {
                LabeledContent("Source capo", value: "\(document.metadata.sourceCapo)")
            }
            if isAligning {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Aligning to this recording…")
                        .foregroundStyle(.secondary)
                }
            } else if let result = alignedPreview {
                LabeledContent(
                    "Alignment",
                    value: result.alignment.statusLabel.capitalized
                )
                LabeledContent(
                    "Placement",
                    value: "\(Int((result.alignment.confidence * 100).rounded()))%"
                )
                LabeledContent(
                    "Lines matched to lyrics",
                    value: "\(Int((result.alignment.lyricAnchorCoverage * 100).rounded()))%"
                )
                pitch(for: result)
                if let agreement = result.alignment.audioAgreement {
                    LabeledContent(
                        "Audio agreement",
                        value: "\(Int((agreement * 100).rounded()))%"
                    )
                } else if !document.lyricAnchors.isEmpty, lyrics.lyrics == nil {
                    Text("This song has no lyrics yet, so chords were placed by order alone. Adding lyrics and re-aligning will place them on the words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Says when the chart is in a different key from the recording, and offers
    /// to move it.
    ///
    /// Never applied silently. A chart a semitone above the record is not a
    /// mistake in the chart — it is what someone playing a tuned-down guitar
    /// wrote down — so the user is told what was found and chooses.
    @ViewBuilder
    private func pitch(for result: UserChordAligner.Result) -> some View {
        if let agreement = result.alignment.pitchAgreement {
            LabeledContent(
                "Matches the recording",
                value: "\(Int((agreement * 100).rounded()))%"
            )
        }
        if let suggested = result.alignment.suggestedPitchOffset,
           suggested != pitchOffset {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "This chart reads \(abs(suggested - pitchOffset)) semitone\(abs(suggested - pitchOffset) == 1 ? "" : "s") \(suggested < pitchOffset ? "above" : "below") this recording.",
                    systemImage: "tuningfork"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Text("The chords are placed correctly; only their pitch differs. A guitar tuned down, or a capo the transcriber assumed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Match This Recording") {
                    pitchOffset = suggested
                    realign()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else if pitchOffset != 0 {
            LabeledContent(
                "Pitch",
                value: "Moved \(abs(pitchOffset)) semitone\(abs(pitchOffset) == 1 ? "" : "s") \(pitchOffset < 0 ? "down" : "up")"
            )
            Button("Keep the Chart as Written") {
                pitchOffset = 0
                realign()
            }
            .controlSize(.small)
        }
    }

    /// Re-runs the alignment off the main actor, cancelling whatever the
    /// previous keystroke started.
    private func realign() {
        alignmentTask?.cancel()
        guard !document.events.isEmpty, let duration = store.song?.duration else {
            alignedPreview = nil
            isAligning = false
            return
        }
        let document = document
        let songLyrics = lyrics.lyrics
        let grid = beats.grid
        let evidence = store.beatEvidence
        let reference = store.detectedChords
        let offset = pitchOffset
        isAligning = true
        alignmentTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                UserChordAligner.align(
                    document,
                    lyrics: songLyrics,
                    grid: grid,
                    duration: duration,
                    evidence: evidence,
                    reference: reference,
                    pitchOffset: offset
                )
            }.value
            guard !Task.isCancelled else { return }
            alignedPreview = result
            isAligning = false
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if !document.warnings.isEmpty {
            Section("Needs attention") {
                ForEach(document.warnings) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func add() {
        let succeeded: Bool
        if let updateChartID {
            succeeded = store.updateUserChart(
                id: updateChartID,
                document: document,
                origin: origin,
                name: chartName,
                lyrics: lyrics.lyrics,
                grid: beats.grid,
                aligned: alignedPreview,
                pitchOffset: pitchOffset
            )
        } else {
            succeeded = store.addUserChart(
                document: document,
                origin: origin,
                name: chartName,
                lyrics: lyrics.lyrics,
                grid: beats.grid,
                aligned: alignedPreview,
                pitchOffset: pitchOffset
            ) != nil
        }
        guard succeeded else { return }
        Haptics.boundarySet()
        dismiss()
    }
}

struct UserChordManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ChordStore
    let lyrics: LyricsStore
    let beats: BeatGridStore
    let addChart: () -> Void

    @State private var renaming: UserChordChart?
    @State private var name = ""
    @State private var sharePayload: SharePayload?

    var body: some View {
        NavigationStack {
            List {
                if let detected = store.detectedChords {
                    Section("Atarang") {
                        Button {
                            store.select(.detected)
                        } label: {
                            sourceRow(
                                title: "Atarang analysis",
                                detail: detected.isReliable ? "Detected locally" : "Detected locally · uncertain",
                                selected: store.userCollection.selectedSource == .detected
                            )
                        }
                        .buttonStyle(.plain)
                        Button("Remove Atarang Analysis", role: .destructive) {
                            store.clearDetected()
                        }
                    }
                }

                Section("Imported charts") {
                    ForEach(store.userCollection.charts) { chart in
                        Button {
                            store.select(.user(chart.id))
                        } label: {
                            sourceRow(
                                title: chart.name,
                                detail: "\(chart.origin.label) · \(chart.alignment?.statusLabel ?? "unaligned")",
                                selected: store.userCollection.selectedSource == .user(chart.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                store.removeUserChart(id: chart.id)
                            }
                        }
                        .contextMenu {
                            Button("Rename") {
                                name = chart.name
                                renaming = chart
                            }
                            Button("Re-align") {
                                store.realignUserChart(
                                    id: chart.id,
                                    lyrics: lyrics.lyrics,
                                    grid: beats.grid
                                )
                            }
                            Button("Export ChordPro") {
                                sharePayload = SharePayload(items: [ChordProExporter.text(for: chart)])
                            }
                            Button("Remove", role: .destructive) {
                                store.removeUserChart(id: chart.id)
                            }
                        }
                        if let alignment = chart.alignment,
                           let suggested = alignment.suggestedPitchOffset,
                           suggested != alignment.pitchOffset {
                            pitchNotice(for: chart, suggested: suggested, from: alignment.pitchOffset)
                        }
                    }
                    Button(action: addChart) {
                        Label("Add another chart", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Chord Charts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Chart", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { store.renameUserChart(id: renaming.id, to: name) }
                    renaming = nil
                }
            }
            .sheet(item: $sharePayload) { payload in
                ActivityView(items: payload.items)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    /// The same offer the import preview makes, for a chart that is already
    /// saved — including one imported before Atarang could notice this.
    private func pitchNotice(
        for chart: UserChordChart,
        suggested: Int,
        from applied: Int
    ) -> some View {
        let distance = abs(suggested - applied)
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                "Reads \(distance) semitone\(distance == 1 ? "" : "s") \(suggested < applied ? "above" : "below") this recording",
                systemImage: "tuningfork"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            Text("The chords are in the right places; only their pitch differs.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Match This Recording") {
                store.realignUserChart(
                    id: chart.id,
                    lyrics: lyrics.lyrics,
                    grid: beats.grid,
                    pitchOffset: suggested
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func sourceRow(title: String, detail: String, selected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.indigo)
                    .accessibilityLabel("Selected")
            }
        }
        .contentShape(Rectangle())
    }
}

struct ChordSourceMenu: View {
    let store: ChordStore
    let add: () -> Void
    let manage: () -> Void

    var body: some View {
        Menu {
            if store.detectedChords != nil {
                Button {
                    store.select(.detected)
                } label: {
                    sourceLabel(
                        "Atarang analysis",
                        selected: store.userCollection.selectedSource == .detected
                    )
                }
            }
            ForEach(store.userCollection.charts.filter { $0.chords != nil }) { chart in
                Button {
                    store.select(.user(chart.id))
                } label: {
                    sourceLabel(
                        chart.name,
                        selected: store.userCollection.selectedSource == .user(chart.id)
                    )
                }
            }
            Divider()
            Button(action: add) {
                Label("Add another chart…", systemImage: "plus")
            }
            Button(action: manage) {
                Label("Manage charts…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.activeSourceLabel)
                        .font(.caption2.weight(.semibold))
                    Text(store.activeSourceDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 30)
            .background(Color.indigo.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("Chord source, \(store.activeSourceLabel)")
    }

    private func sourceLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }
}
