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
            .onChange(of: text) { _, value in
                document = UserChordParser.parse(value)
                if chartName == "My chart", let title = document.metadata.title {
                    chartName = title
                }
            }
        }
    }

    private var disclosure: some View {
        Section {
            Label("Processed entirely on this device", systemImage: "iphone.and.arrow.forward")
                .foregroundStyle(.green)
            Text("Import a chart you created or are allowed to use. Atarang reads and aligns it on this device; it does not contact the chart’s source.")
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
            if let result = UserChordAligner.align(
                document,
                lyrics: lyrics.lyrics,
                grid: beats.grid,
                duration: store.song?.duration ?? 0,
                evidence: store.beatEvidence
            ) {
                LabeledContent(
                    "Alignment",
                    value: result.alignment.statusLabel.capitalized
                )
                LabeledContent(
                    "Placement",
                    value: "\(Int((result.alignment.confidence * 100).rounded()))%"
                )
                if let agreement = result.alignment.audioAgreement {
                    LabeledContent(
                        "Audio agreement",
                        value: "\(Int((agreement * 100).rounded()))%"
                    )
                }
            }
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
                grid: beats.grid
            )
        } else {
            succeeded = store.addUserChart(
                document: document,
                origin: origin,
                name: chartName,
                lyrics: lyrics.lyrics,
                grid: beats.grid
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
