import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var audioPlayer: HistoryAudioPlayer
    let audioPlaybackDisabled: Bool
    let openTrack: (HistoryTrack, Bool) -> Void
    let recordTrack: (HistoryTrack) -> Void
    let recordAgain: (HistoryRecording) -> Void

    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var shareItems: [URL] = []
    @State private var showingShareSheet = false
    @State private var deletion: DeletionTarget?

    var body: some View {
        NavigationStack {
            Group {
                if store.tracks.isEmpty && store.recordings.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Separated songs and recorded performances will appear here automatically.")
                    )
                } else if filteredTracks.isEmpty && filteredRecordings.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    historyList
                }
            }
            .navigationTitle("History")
            .searchable(text: $query, prompt: "Search songs and recordings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            ForEach(HistoryFilter.allCases) { value in
                                Label(value.title, systemImage: value.icon).tag(value)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .refreshable { store.refresh() }
            .sheet(isPresented: $showingShareSheet) {
                ActivityView(items: shareItems)
                    .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                deletion.map { "Delete “\($0.title)” ?" } ?? "Delete item?",
                isPresented: Binding(
                    get: { deletion != nil },
                    set: { if !$0 { deletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete permanently", role: .destructive) { performDeletion() }
                Button("Cancel", role: .cancel) { deletion = nil }
            } message: {
                Text("This removes the saved audio from this iPhone. This can’t be undone.")
            }
            .alert("History problem", isPresented: errorIsPresented) {
                Button("OK") {
                    store.errorMessage = nil
                    audioPlayer.errorMessage = nil
                }
            } message: {
                Text(store.errorMessage ?? audioPlayer.errorMessage ?? "Unknown error")
            }
        }
    }

    private var historyList: some View {
        List {
            if !filteredTracks.isEmpty {
                Section("Separated songs") {
                    ForEach(filteredTracks) { track in
                        trackRow(track)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirmDelete(track) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { share(track.files.values.sorted { $0.lastPathComponent < $1.lastPathComponent }) } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.indigo)
                            }
                            .contextMenu { trackActions(track) }
                    }
                }
            }

            if !filteredRecordings.isEmpty {
                Section("Performances") {
                    ForEach(filteredRecordings) { recording in
                        recordingRow(recording)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { confirmDelete(recording) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if let url = recording.playbackURL {
                                    Button { share([url]) } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.indigo)
                                }
                            }
                            .contextMenu { recordingActions(recording) }
                    }
                }
            }

            Section {
                HStack {
                    Label("Stored on this iPhone", systemImage: "internaldrive")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func trackRow(_ track: HistoryTrack) -> some View {
        HStack(spacing: 13) {
            historyArtwork(systemImage: "waveform", color: .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                metadataLine(date: track.createdAt, duration: track.duration, bytes: track.byteCount)
            }
            Spacer(minLength: 4)
            Button { openTrack(track, true) } label: {
                Image(systemName: "play.fill")
                    .frame(width: 34, height: 34)
                    .background(.indigo.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { openTrack(track, false) }
        .accessibilityHint("Opens this song in the mixer")
    }

    private func recordingRow(_ recording: HistoryRecording) -> some View {
        HStack(spacing: 13) {
            historyArtwork(systemImage: "mic.fill", color: .red)
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                metadataLine(date: recording.createdAt, duration: recording.duration, bytes: recording.byteCount)
            }
            Spacer(minLength: 4)
            if let url = recording.playbackURL {
                Button {
                    audioPlayer.toggle(id: recording.id, url: url)
                } label: {
                    Image(systemName: audioPlayer.playingID == recording.id && audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 34, height: 34)
                        .background(.red.opacity(0.11), in: Circle())
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(audioPlaybackDisabled)
                .accessibilityLabel(audioPlayer.playingID == recording.id && audioPlayer.isPlaying ? "Pause recording" : "Play recording")
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shareable recording unavailable")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func trackActions(_ track: HistoryTrack) -> some View {
        Button { openTrack(track, true) } label: {
            Label("Play", systemImage: "play.fill")
        }
        Button { openTrack(track, false) } label: {
            Label("Open mixer", systemImage: "slider.horizontal.3")
        }
        Button { recordTrack(track) } label: {
            Label("Record again", systemImage: "record.circle")
        }
        Button { share(track.files.values.sorted { $0.lastPathComponent < $1.lastPathComponent }) } label: {
            Label("Share four stems", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) { confirmDelete(track) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func recordingActions(_ recording: HistoryRecording) -> some View {
        if let url = recording.playbackURL {
            Button { audioPlayer.toggle(id: recording.id, url: url) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .disabled(audioPlaybackDisabled)
            Button { share([url]) } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        Button { recordAgain(recording) } label: {
            Label("Record again", systemImage: "record.circle")
        }
        .disabled(recording.sourceTrackID == nil || store.track(withID: recording.sourceTrackID ?? UUID()) == nil)
        Divider()
        Button(role: .destructive) { confirmDelete(recording) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func historyArtwork(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .frame(width: 46, height: 46)
            .foregroundStyle(color)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metadataLine(date: Date, duration: TimeInterval, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Text(date, style: .relative)
            Text("·")
            Text(time(duration))
            Text("·")
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var filteredTracks: [HistoryTrack] {
        guard filter != .recordings else { return [] }
        return store.tracks.filter { matches($0.title, type: "separated song stems") }
    }

    private var filteredRecordings: [HistoryRecording] {
        guard filter != .tracks else { return [] }
        return store.recordings.filter { matches($0.title, type: "recorded performance") }
    }

    private func matches(_ title: String, type: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || title.localizedCaseInsensitiveContains(term) || type.localizedCaseInsensitiveContains(term)
    }

    private var totalBytes: Int64 {
        store.tracks.reduce(0) { $0 + $1.byteCount } + store.recordings.reduce(0) { $0 + $1.byteCount }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil || audioPlayer.errorMessage != nil },
            set: {
                if !$0 {
                    store.errorMessage = nil
                    audioPlayer.errorMessage = nil
                }
            }
        )
    }

    private func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        shareItems = urls
        showingShareSheet = true
    }

    private func confirmDelete(_ track: HistoryTrack) {
        deletion = DeletionTarget(id: track.id, title: track.title, kind: .track)
    }

    private func confirmDelete(_ recording: HistoryRecording) {
        deletion = DeletionTarget(id: recording.id, title: recording.title, kind: .recording)
    }

    private func performDeletion() {
        guard let deletion else { return }
        switch deletion.kind {
        case .track:
            if let track = store.track(withID: deletion.id) { store.delete(track: track) }
        case .recording:
            if let recording = store.recordings.first(where: { $0.id == deletion.id }) {
                if audioPlayer.playingID == recording.id { audioPlayer.stop() }
                store.delete(recording: recording)
            }
        }
        self.deletion = nil
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, tracks, recordings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Everything"
        case .tracks: "Separated songs"
        case .recordings: "Performances"
        }
    }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .tracks: "waveform"
        case .recordings: "mic.fill"
        }
    }
}

private struct DeletionTarget {
    enum Kind { case track, recording }
    let id: UUID
    let title: String
    let kind: Kind
}
