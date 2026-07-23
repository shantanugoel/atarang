import SwiftUI

enum LibrarySeparationSource: Sendable {
    case original(HistoryOriginal)
    case track(HistoryTrack)
}

struct HistoryView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var store: HistoryStore
    @ObservedObject var audioPlayer: HistoryAudioPlayer
    let audioPlaybackDisabled: Bool
    let openTrack: (HistoryTrack, Bool) -> Void
    let recordTrack: (HistoryTrack) -> Void
    let recordAgain: (HistoryRecording) -> Void
    let separateSource: (LibrarySeparationSource, SeparationModelKind) -> Void
    let createFirstSeparation: () -> Void

    @State private var query = ""
    @State private var category: LibraryCategory = .separations
    @State private var expandedItem: LibraryItemID?
    @State private var sharePayload: SharePayload?
    @State private var editingMix: HistoryRecording?
    @State private var deletion: DeletionTarget?
    @State private var separationRequest: SeparationRequest?
    @State private var isSelecting = false
    @State private var selectedItems: Set<LibraryItemID> = []
    @State private var showsBatchDeleteConfirmation = false
    @State private var unavailableActionMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Picker("Library category", selection: $category) {
                            ForEach(LibraryCategory.allCases) { category in
                                Label(category.title, systemImage: category.icon).tag(category)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Library category", selection: $category) {
                            ForEach(LibraryCategory.allCases) { category in
                                Text(category.title).tag(category)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .disabled(isSelecting)
                .padding(.horizontal)
                .padding(.bottom, 10)

                Group {
                    if store.originals.isEmpty && store.tracks.isEmpty && store.recordings.isEmpty {
                        emptyLibraryView
                    } else if visibleItemCount == 0 {
                        emptyCategoryView
                    } else {
                        libraryList
                    }
                }
            }
            .frame(maxWidth: horizontalSizeClass == .regular ? 1000 : .infinity)
            .frame(maxWidth: .infinity)
            .navigationTitle("Library")
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(allVisibleItemsSelected ? "Deselect All" : "Select All") {
                            toggleSelectAll()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { endSelection() }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Select") { beginSelection() }
                            .disabled(visibleItemCount == 0)
                    }
                }
            }
            .searchable(text: $query, prompt: "Search \(category.searchPrompt)")
            .refreshable { store.refresh() }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .atarangUnavailableLibraryAction
                )
            ) { notification in
                unavailableActionMessage = notification.object as? String
            }
            .onChange(of: category) {
                endSelection()
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    selectionBar
                }
            }
            .sheet(item: $sharePayload) { payload in
                ActivityView(items: payload.items)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editingMix) { recording in
                RecordingMixEditor(store: store, recording: recording)
                    .presentationDetents([.large])
            }
            .sheet(item: $separationRequest) { request in
                SeparationChoiceSheet(request: request) { model in
                    separationRequest = nil
                    Task { @MainActor in
                        await Task.yield()
                        separateSource(request.source, model)
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showsBatchDeleteConfirmation) {
                BatchDeleteConfirmationSheet(
                    count: selectedItems.count,
                    byteCount: selectedBytes,
                    itemName: category.batchItemName,
                    consequence: batchDeletionConsequence
                ) {
                    performBatchDeletion()
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .alert("Library problem", isPresented: errorIsPresented) {
                Button("OK") {
                    store.errorMessage = nil
                    audioPlayer.errorMessage = nil
                }
            } message: {
                Text(store.errorMessage ?? audioPlayer.errorMessage ?? "Unknown error")
            }
            .alert(
                "Action unavailable",
                isPresented: Binding(
                    get: { unavailableActionMessage != nil },
                    set: { if !$0 { unavailableActionMessage = nil } }
                )
            ) {
                Button("OK") { unavailableActionMessage = nil }
            } message: {
                Text(unavailableActionMessage ?? "")
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("Your library is empty", systemImage: "music.note.house")
        } description: {
            Text("Original songs, separations, and performances will appear here.")
        } actions: {
            Button("Separate Your First Song") {
                createFirstSeparation()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var libraryList: some View {
        List {
            Section {
                switch category {
                case .originals:
                    ForEach(filteredOriginals) { original in
                        originalRow(original)
                    }
                case .separations:
                    ForEach(filteredTracks) { track in
                        trackRow(track)
                    }
                case .performances:
                    ForEach(filteredRecordings) { recording in
                        recordingRow(recording)
                    }
                }
            }

            Section {
                HStack {
                    Label(category.storageLabel, systemImage: "internaldrive")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: categoryBytes, countStyle: .file))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyCategoryView: some View {
        ContentUnavailableView {
            Label(
                query.isEmpty ? category.emptyTitle : "No Results",
                systemImage: query.isEmpty ? category.icon : "magnifyingglass"
            )
        } description: {
            Text(
                query.isEmpty
                    ? category.emptyDescription
                    : "No \(category.searchPrompt) match “\(query)”."
            )
        } actions: {
            if query.isEmpty {
                Button("Go to Studio") {
                    createFirstSeparation()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Clear Search") {
                    query = ""
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func originalRow(_ original: HistoryOriginal) -> some View {
        let item = LibraryItemID(kind: .original, id: original.id)
        return VStack(spacing: 0) {
            libraryRowHeader(
                title: original.title,
                date: original.createdAt,
                duration: original.duration,
                bytes: original.byteCount,
                systemImage: "arrow.down.circle.fill",
                color: .blue,
                item: item,
                primaryIcon: playIcon(for: original.id),
                primaryLabel: audioPlayer.playingID == original.id && audioPlayer.isPlaying
                    ? "Pause original"
                    : "Play original"
            ) {
                audioPlayer.toggle(id: original.id, url: original.audioURL)
            }

            if !isSelecting, expandedItem == item {
                Divider().padding(.top, 5)
                if deletion?.item == item {
                    inlineDeletion
                } else {
                    HStack(spacing: 3) {
                        LibraryAction(title: "Play", systemImage: playIcon(for: original.id)) {
                            audioPlayer.toggle(id: original.id, url: original.audioURL)
                        }
                        LibraryAction(title: "Separate", systemImage: "waveform.path.ecg") {
                            requestSeparation(for: original)
                        }
                        LibraryAction(title: "Share", systemImage: "square.and.arrow.up") {
                            share([original.audioURL])
                        }
                        Menu {
                            Link(destination: original.sourceURL) {
                                Label("View Source", systemImage: "safari")
                            }
                            Button(role: .destructive) {
                                requestDeletion(
                                    item: item,
                                    title: original.title,
                                    kind: .original
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            LibraryActionLabel(title: "More", systemImage: "ellipsis")
                        }
                    }
                    .padding(.top, 5)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: expandedItem)
    }

    private func trackRow(_ track: HistoryTrack) -> some View {
        let item = LibraryItemID(kind: .track, id: track.id)
        return VStack(spacing: 0) {
            libraryRowHeader(
                title: track.title,
                subtitle: "\(track.activeStemCount)-stem · \(track.separationModel.title)",
                date: track.createdAt,
                duration: track.duration,
                bytes: track.byteCount,
                systemImage: "waveform",
                color: .indigo,
                item: item,
                primaryIcon: "slider.horizontal.3",
                primaryLabel: "Open mixer"
            ) {
                openTrack(track, false)
            }

            if !isSelecting, expandedItem == item {
                Divider().padding(.top, 5)
                if deletion?.item == item {
                    inlineDeletion
                } else {
                    HStack(spacing: 3) {
                        LibraryAction(title: "Play", systemImage: "play.fill") {
                            openTrack(track, true)
                        }
                        LibraryAction(title: "Record", systemImage: "record.circle") {
                            recordTrack(track)
                        }
                        LibraryAction(
                            title: "Separate",
                            systemImage: "arrow.triangle.branch",
                            unavailableReason: canSeparateAgain(track)
                                ? nil
                                : "The original source for this separation is no longer available."
                        ) {
                            requestSeparation(for: track)
                        }
                        Menu {
                            Button {
                                share(track.files.values.sorted {
                                    $0.lastPathComponent < $1.lastPathComponent
                                })
                            } label: {
                                Label("Share \(track.files.count) Stems", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                requestDeletion(
                                    item: item,
                                    title: track.title,
                                    kind: .track
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            LibraryActionLabel(title: "More", systemImage: "ellipsis")
                        }
                    }
                    .padding(.top, 5)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: expandedItem)
    }

    private func recordingRow(_ recording: HistoryRecording) -> some View {
        let item = LibraryItemID(kind: .recording, id: recording.id)
        return VStack(spacing: 0) {
            libraryRowHeader(
                title: recording.title,
                date: recording.createdAt,
                duration: recording.duration,
                bytes: recording.byteCount,
                systemImage: "mic.fill",
                color: .red,
                item: item,
                primaryIcon: playIcon(for: recording.id),
                primaryLabel: audioPlayer.playingID == recording.id && audioPlayer.isPlaying
                    ? "Pause performance"
                    : "Play performance",
                primaryEnabled: recording.playbackURL != nil
            ) {
                if let url = recording.playbackURL {
                    audioPlayer.toggle(id: recording.id, url: url)
                }
            }

            if !isSelecting, expandedItem == item {
                Divider().padding(.top, 5)
                if deletion?.item == item {
                    inlineDeletion
                } else {
                    HStack(spacing: 3) {
                        LibraryAction(
                            title: "Edit Mix",
                            systemImage: "slider.horizontal.3",
                            unavailableReason: recording.canEditMix
                                ? nil
                                : "The raw microphone and backing files for this older performance are unavailable."
                        ) {
                            editMix(recording)
                        }
                        LibraryAction(
                            title: "Share",
                            systemImage: "square.and.arrow.up",
                            unavailableReason: recording.playbackURL == nil
                                ? "This performance does not have an exported audio file to share."
                                : nil
                        ) {
                            if let url = recording.playbackURL { share([url]) }
                        }
                        LibraryAction(
                            title: "Record",
                            systemImage: "record.circle",
                            unavailableReason: canRecordAgain(recording)
                                ? nil
                                : "The separated song used for this performance is no longer available."
                        ) {
                            recordAgain(recording)
                        }
                        Menu {
                            Button(role: .destructive) {
                                requestDeletion(
                                    item: item,
                                    title: recording.title,
                                    kind: .recording
                                )
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            LibraryActionLabel(title: "More", systemImage: "ellipsis")
                        }
                    }
                    .padding(.top, 5)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: expandedItem)
    }

    private func libraryRowHeader(
        title: String,
        subtitle: String? = nil,
        date: Date,
        duration: TimeInterval,
        bytes: Int64,
        systemImage: String,
        color: Color,
        item: LibraryItemID,
        primaryIcon: String,
        primaryLabel: String,
        primaryEnabled: Bool = true,
        primaryAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 46, height: 46)
                .foregroundStyle(color)
                .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
                metadataLine(date: date, duration: duration, bytes: bytes)
            }
            Spacer(minLength: 4)
            if isSelecting {
                Image(
                    systemName: selectedItems.contains(item)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title2)
                .foregroundStyle(selectedItems.contains(item) ? Color.indigo : .secondary)
                .frame(width: 42, height: 42)
                .accessibilityLabel(
                    selectedItems.contains(item) ? "Selected" : "Not selected"
                )
            } else {
                Button(action: primaryAction) {
                    Image(systemName: primaryIcon)
                        .frame(width: 34, height: 34)
                        .background(color.opacity(0.11), in: Circle())
                        .foregroundStyle(color)
                }
                .buttonStyle(.plain)
                .disabled(audioPlaybackDisabled || !primaryEnabled)
                .accessibilityLabel(primaryLabel)

                Image(systemName: expandedItem == item ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelection(of: item)
            } else {
                deletion = nil
                expandedItem = expandedItem == item ? nil : item
            }
        }
        .accessibilityHint(
            isSelecting ? "Toggles selection" : "Shows actions for this item"
        )
        .accessibilityValue(expandedItem == item ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: isSelecting ? "Toggle selection" : "Show actions") {
            if isSelecting {
                toggleSelection(of: item)
            } else {
                deletion = nil
                expandedItem = expandedItem == item ? nil : item
            }
        }
    }

    private var inlineDeletion: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    deletionCopy
                    HStack {
                        Button("Cancel") { deletion = nil }
                            .buttonStyle(.bordered)
                        Button("Delete", role: .destructive) { performDeletion() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    deletionCopy
                    Spacer(minLength: 4)
                    Button("Cancel") { deletion = nil }
                        .buttonStyle(.bordered)
                    Button("Delete", role: .destructive) { performDeletion() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var deletionCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Delete “\(deletion?.title ?? "item")”?")
                .font(.subheadline.weight(.semibold))
            Text(deletion?.message ?? "This permanently removes its saved audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    selectedItems.isEmpty
                        ? "Select items"
                        : "\(selectedItems.count) selected"
                )
                .font(.subheadline.weight(.semibold))
                Text(
                    selectedItems.isEmpty
                        ? "Choose items to manage"
                        : ByteCountFormatter.string(
                            fromByteCount: selectedBytes,
                            countStyle: .file
                        )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                showsBatchDeleteConfirmation = true
            } label: {
                Label(
                    selectedItems.isEmpty
                        ? "Delete"
                        : "Delete \(selectedItems.count)",
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var filteredOriginals: [HistoryOriginal] {
        store.originals.filter { matches($0.title) }
    }

    private var filteredTracks: [HistoryTrack] {
        store.tracks.filter { matches($0.title) }
    }

    private var filteredRecordings: [HistoryRecording] {
        store.recordings.filter { matches($0.title) }
    }

    private var visibleItemCount: Int {
        switch category {
        case .originals: filteredOriginals.count
        case .separations: filteredTracks.count
        case .performances: filteredRecordings.count
        }
    }

    private var visibleItemIDs: [LibraryItemID] {
        switch category {
        case .originals:
            filteredOriginals.map {
                LibraryItemID(kind: .original, id: $0.id)
            }
        case .separations:
            filteredTracks.map {
                LibraryItemID(kind: .track, id: $0.id)
            }
        case .performances:
            filteredRecordings.map {
                LibraryItemID(kind: .recording, id: $0.id)
            }
        }
    }

    private var allVisibleItemsSelected: Bool {
        !visibleItemIDs.isEmpty
            && visibleItemIDs.allSatisfy(selectedItems.contains)
    }

    private var selectedBytes: Int64 {
        switch category {
        case .originals:
            store.originals
                .filter {
                    selectedItems.contains(
                        LibraryItemID(kind: .original, id: $0.id)
                    )
                }
                .reduce(0) { $0 + $1.byteCount }
        case .separations:
            store.tracks
                .filter {
                    selectedItems.contains(
                        LibraryItemID(kind: .track, id: $0.id)
                    )
                }
                .reduce(0) { $0 + $1.byteCount }
        case .performances:
            store.recordings
                .filter {
                    selectedItems.contains(
                        LibraryItemID(kind: .recording, id: $0.id)
                    )
                }
                .reduce(0) { $0 + $1.byteCount }
        }
    }

    private var categoryBytes: Int64 {
        switch category {
        case .originals: store.originals.reduce(0) { $0 + $1.byteCount }
        case .separations: store.tracks.reduce(0) { $0 + $1.byteCount }
        case .performances: store.recordings.reduce(0) { $0 + $1.byteCount }
        }
    }

    private var batchDeletionConsequence: String? {
        let ids = Set(selectedItems.map(\.id))
        switch category {
        case .originals:
            let related = store.tracks.filter {
                guard let sourceOriginalID = $0.sourceOriginalID else { return false }
                return ids.contains(sourceOriginalID)
            }.count
            return related == 0
                ? nil
                : "\(related) saved separation\(related == 1 ? "" : "s") will remain, but regenerating them may require another download."
        case .separations:
            let related = store.recordings.filter {
                guard let sourceTrackID = $0.sourceTrackID else { return false }
                return ids.contains(sourceTrackID)
            }.count
            return related == 0
                ? nil
                : "\(related) performance\(related == 1 ? "" : "s") will remain, but Record Again will be unavailable."
        case .performances:
            return nil
        }
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

    private func matches(_ title: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || title.localizedCaseInsensitiveContains(term)
    }

    private func beginSelection() {
        audioPlayer.stop(releaseSession: true)
        expandedItem = nil
        deletion = nil
        selectedItems.removeAll()
        isSelecting = true
    }

    private func endSelection() {
        isSelecting = false
        selectedItems.removeAll()
        expandedItem = nil
        deletion = nil
        showsBatchDeleteConfirmation = false
    }

    private func toggleSelection(of item: LibraryItemID) {
        if selectedItems.contains(item) {
            selectedItems.remove(item)
        } else {
            selectedItems.insert(item)
        }
    }

    private func toggleSelectAll() {
        if allVisibleItemsSelected {
            selectedItems.subtract(visibleItemIDs)
        } else {
            selectedItems.formUnion(visibleItemIDs)
        }
    }

    private func performBatchDeletion() {
        let ids = Set(selectedItems.map(\.id))
        if let playingID = audioPlayer.playingID, ids.contains(playingID) {
            audioPlayer.stop()
        }
        switch category {
        case .originals:
            store.delete(originals: store.originals.filter { ids.contains($0.id) })
        case .separations:
            store.delete(tracks: store.tracks.filter { ids.contains($0.id) })
        case .performances:
            store.delete(recordings: store.recordings.filter { ids.contains($0.id) })
        }
        endSelection()
    }

    private func share(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sharePayload = SharePayload(items: urls)
    }

    private func editMix(_ recording: HistoryRecording) {
        guard recording.canEditMix else { return }
        audioPlayer.stop(releaseSession: true)
        editingMix = recording
    }

    private func requestSeparation(for original: HistoryOriginal) {
        audioPlayer.stop(releaseSession: true)
        separationRequest = SeparationRequest(
            title: original.title,
            source: .original(original),
            initialModel: .htdemucs,
            requiresDownload: false
        )
    }

    private func requestSeparation(for track: HistoryTrack) {
        let source: LibrarySeparationSource
        let requiresDownload: Bool
        if let id = track.sourceOriginalID, let original = store.original(withID: id) {
            source = .original(original)
            requiresDownload = false
        } else {
            source = .track(track)
            requiresDownload = true
        }
        separationRequest = SeparationRequest(
            title: track.title,
            source: source,
            initialModel: track.separationModel,
            requiresDownload: requiresDownload
        )
    }

    private func canSeparateAgain(_ track: HistoryTrack) -> Bool {
        if let id = track.sourceOriginalID, store.original(withID: id) != nil {
            return true
        }
        return track.sourceURL != nil
    }

    private func canRecordAgain(_ recording: HistoryRecording) -> Bool {
        guard let id = recording.sourceTrackID else { return false }
        return store.track(withID: id) != nil
    }

    private func requestDeletion(
        item: LibraryItemID,
        title: String,
        kind: DeletionTarget.Kind
    ) {
        let message: String
        switch kind {
        case .original:
            let relatedTracks = store.tracks.filter { $0.sourceOriginalID == item.id }
            let trackIDs = Set(relatedTracks.map(\.id))
            let relatedRecordings = store.recordings.filter {
                guard let sourceTrackID = $0.sourceTrackID else { return false }
                return trackIDs.contains(sourceTrackID)
            }
            if relatedTracks.isEmpty {
                message = "This permanently removes the downloaded original audio."
            } else {
                message = "Its \(relatedTracks.count) separation\(relatedTracks.count == 1 ? "" : "s") remain, but cannot be regenerated without downloading again. \(relatedRecordings.count) related performance\(relatedRecordings.count == 1 ? "" : "s") remain playable."
            }
        case .track:
            let relatedCount = store.recordings.filter {
                $0.sourceTrackID == item.id
            }.count
            message = relatedCount == 0
                ? "This permanently removes all of its saved stems."
                : "\(relatedCount) performance\(relatedCount == 1 ? "" : "s") remain playable, but “Record Again” will no longer be available."
        case .recording:
            message = "This permanently removes the performance and its saved audio."
        }
        expandedItem = item
        withAnimation(.snappy(duration: 0.2)) {
            deletion = DeletionTarget(
                item: item,
                title: title,
                kind: kind,
                message: message
            )
        }
    }

    private func performDeletion() {
        guard let deletion else { return }
        switch deletion.kind {
        case .original:
            if let original = store.originals.first(where: { $0.id == deletion.item.id }) {
                if audioPlayer.playingID == original.id { audioPlayer.stop() }
                store.delete(original: original)
            }
        case .track:
            if let track = store.track(withID: deletion.item.id) {
                store.delete(track: track)
            }
        case .recording:
            if let recording = store.recordings.first(where: { $0.id == deletion.item.id }) {
                if audioPlayer.playingID == recording.id { audioPlayer.stop() }
                store.delete(recording: recording)
            }
        }
        self.deletion = nil
        expandedItem = nil
    }

    private func playIcon(for id: UUID) -> String {
        audioPlayer.playingID == id && audioPlayer.isPlaying ? "pause.fill" : "play.fill"
    }

    private func metadataLine(date: Date, duration: TimeInterval, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Text(roughAge(date))
            Text("·")
            Text(time(duration))
            Text("·")
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }

    private func roughAge(_ date: Date) -> String {
        let age = max(0, Date().timeIntervalSince(date))
        return switch age {
        case ..<3_600: "Now"
        case ..<86_400:
            "\(max(1, Int(age / 3_600)))h ago"
        case ..<604_800:
            "\(max(1, Int(age / 86_400)))d ago"
        case ..<2_592_000:
            "\(max(1, Int(age / 604_800)))w ago"
        default:
            date.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum LibraryCategory: String, CaseIterable, Identifiable {
    case originals, separations, performances
    var id: String { rawValue }

    var title: String {
        switch self {
        case .originals: "Originals"
        case .separations: "Separated"
        case .performances: "Performances"
        }
    }

    var icon: String {
        switch self {
        case .originals: "arrow.down.circle"
        case .separations: "waveform"
        case .performances: "mic.fill"
        }
    }

    var searchPrompt: String {
        switch self {
        case .originals: "original songs"
        case .separations: "separated songs"
        case .performances: "performances"
        }
    }

    var storageLabel: String {
        switch self {
        case .originals: "Originals on this device"
        case .separations: "Separations on this device"
        case .performances: "Performances on this device"
        }
    }

    var emptyTitle: String {
        switch self {
        case .originals: "No Originals"
        case .separations: "No Separations"
        case .performances: "No Performances"
        }
    }

    var emptyDescription: String {
        switch self {
        case .originals:
            "Songs downloaded for separation will stay here for quick reuse."
        case .separations:
            "Separate an original song to create playable stems."
        case .performances:
            "Your recorded performances will appear here."
        }
    }

    var batchItemName: String {
        switch self {
        case .originals: "originals"
        case .separations: "separations"
        case .performances: "performances"
        }
    }
}

private struct LibraryItemID: Hashable {
    enum Kind { case original, track, recording }
    let kind: Kind
    let id: UUID
}

private struct BatchDeleteConfirmationSheet: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let count: Int
    let byteCount: Int64
    let itemName: String
    let consequence: String?
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash")
                .font(.title2)
                .foregroundStyle(.red)
                .frame(width: 48, height: 48)
                .background(.red.opacity(0.1), in: Circle())
            VStack(spacing: 5) {
                Text("Delete \(count) \(itemName)?")
                    .font(.headline)
                Text(
                    "This permanently removes \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) of saved audio."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                if let consequence {
                    Text(consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack {
                        deleteButton
                        cancelButton
                    }
                } else {
                    HStack {
                        cancelButton
                        deleteButton
                    }
                }
            }
        }
        .padding()
    }

    private var cancelButton: some View {
        Button("Cancel") { dismiss() }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive) {
            dismiss()
            onDelete()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .frame(maxWidth: .infinity)
    }
}

private struct DeletionTarget {
    enum Kind { case original, track, recording }
    let item: LibraryItemID
    let title: String
    let kind: Kind
    let message: String
}

private struct SeparationRequest: Identifiable {
    let id = UUID()
    let title: String
    let source: LibrarySeparationSource
    let initialModel: SeparationModelKind
    let requiresDownload: Bool
}

private struct SeparationChoiceSheet: View {
    let request: SeparationRequest
    let onSeparate: (SeparationModelKind) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: SeparationModelKind

    init(
        request: SeparationRequest,
        onSeparate: @escaping (SeparationModelKind) -> Void
    ) {
        self.request = request
        self.onSeparate = onSeparate
        _model = State(
            initialValue: request.initialModel.isAvailableOnCurrentDevice
                ? request.initialModel
                : .htdemucs
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Algorithm", selection: $model) {
                        ForEach(SeparationModelKind.allCases) { model in
                            Text(
                                model.isAvailableOnCurrentDevice
                                    ? model.title
                                    : "\(model.title) — unavailable"
                            )
                            .tag(model)
                            .disabled(!model.isAvailableOnCurrentDevice)
                        }
                    }
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.stemSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    if request.requiresDownload {
                        Text("The saved original is unavailable, so Atarang will download it again.")
                    } else {
                        Text("Uses the saved original—no download needed.")
                    }
                }

                Section {
                    Button {
                        onSeparate(model)
                    } label: {
                        Label(
                            "Create \(model.stems.count)-Stem Separation",
                            systemImage: "waveform.path.ecg"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isAvailableOnCurrentDevice)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Separate Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct LibraryAction: View {
    let title: String
    let systemImage: String
    var unavailableReason: String?
    let action: () -> Void

    var body: some View {
        Button {
            if let unavailableReason {
                NotificationCenter.default.post(
                    name: .atarangUnavailableLibraryAction,
                    object: unavailableReason
                )
            } else {
                action()
            }
        } label: {
            LibraryActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .opacity(unavailableReason == nil ? 1 : 0.48)
        .accessibilityHint(unavailableReason ?? "")
    }
}

private extension Notification.Name {
    static let atarangUnavailableLibraryAction = Notification.Name(
        "AtarangUnavailableLibraryAction"
    )
}

private struct LibraryActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
            Text(title)
                .font(.caption2)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }
}

private extension HistoryTrack {
    var activeStemCount: Int { files.count }
}
