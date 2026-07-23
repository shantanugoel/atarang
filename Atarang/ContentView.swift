import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("didExplainRecording") private var didExplainRecording = false
    @AppStorage("hasUsedStudio") private var hasUsedStudio = false
    @StateObject private var model = SeparationModel()
    @StateObject private var player = StemPlayer()
    @StateObject private var history = HistoryStore()
    @StateObject private var historyAudioPlayer = HistoryAudioPlayer()
    @State private var youtubeURL: String
    @State private var didRunDebugURL = false
    @State private var sharePayload: SharePayload?
    @State private var selectedTab = AppTab.studio
    @State private var existingSeparation: LocalTrack?
    @State private var existingModels: [SeparationModelKind] = []
    @State private var separationTask: Task<Void, Never>?
    @State private var existingLookupTask: Task<Void, Never>?
    @State private var pendingModelDownload: ModelDownloadRequest?
    @State private var studioNotice: String?
    @State private var showsRecordingIntroduction = false
    private let debugURL: String?

    init() {
        let value = ProcessInfo.processInfo.environment["ATARANG_DEBUG_URL"]
        debugURL = value
        _youtubeURL = State(initialValue: value ?? "")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 22) {
                        if !player.isLoaded,
                           !hasUsedStudio,
                           !dynamicTypeSize.isAccessibilitySize {
                            hero
                        }
                        if let studioNotice {
                            noticeBanner(studioNotice)
                        }
                        if player.isLoaded {
                            mixerHeader
                            mixer
                        } else {
                            importCard
                        }
                        if model.isWorking { progressCard }
                    }
                    .padding()
                    .frame(
                        maxWidth: horizontalSizeClass == .regular ? 760 : .infinity
                    )
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.isLoaded {
                        compactTransport
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.bar)
                    }
                }
                .navigationTitle("Atarang")
                .navigationBarTitleDisplayMode(.large)
                .toolbar(player.isLoaded ? .hidden : .visible, for: .navigationBar)
                .alert("Couldn’t separate this song", isPresented: errorIsPresented) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "Unknown error")
                }
                .alert("Audio problem", isPresented: playerErrorIsPresented) {
                    if player.microphonePermissionDenied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    Button("OK") { player.alertMessage = nil }
                } message: {
                    Text(player.alertMessage ?? "Unknown audio error")
                }
                .alert(item: $pendingModelDownload) { request in
                    Alert(
                        title: Text("Download \(model.selectedModel.downloadSize ?? "model")?"),
                        message: Text(
                            "\(model.selectedModel.title) is downloaded once and kept on this device. Separation begins after the download finishes."
                        ),
                        primaryButton: .default(Text("Download and Continue")) {
                            startSeparation(force: request.force)
                        },
                        secondaryButton: .cancel()
                    )
                }
                .sheet(item: $sharePayload) { payload in
                    ActivityView(items: payload.items)
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showsRecordingIntroduction) {
                    RecordingIntroductionSheet {
                        didExplainRecording = true
                        showsRecordingIntroduction = false
                        Task { await player.toggleRecording() }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            .tabItem { Label("Studio", systemImage: "slider.horizontal.3") }
            .tag(AppTab.studio)

            HistoryView(
                store: history,
                audioPlayer: historyAudioPlayer,
                audioPlaybackDisabled: player.isRecording,
                openTrack: openHistoryTrack,
                recordTrack: startRecording,
                recordAgain: recordAgain,
                separateSource: separateLibrarySource,
                createFirstSeparation: {
                    selectedTab = .studio
                }
            )
            .tabItem { Label("Library", systemImage: "music.note.house") }
            .tag(AppTab.history)
        }
        .background(KeyboardDismissController())
        .tint(.indigo)
        .onReceive(NotificationCenter.default.publisher(for: .atarangLibraryDidChange)) { _ in
            history.refresh()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history, !player.isRecording {
                player.suspend()
            } else if tab == .studio {
                historyAudioPlayer.stop()
            }
        }
        .onChange(of: youtubeURL) { refreshExistingSeparation() }
        .onChange(of: model.selectedModel) { refreshExistingSeparation() }
        .onOpenURL(perform: handleIncomingURL)
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            consumePendingImport()
        }
        .task {
            consumePendingImport()
            guard !didRunDebugURL, let debugURL, !debugURL.isEmpty else { return }
            didRunDebugURL = true
            await separate(debugURL, force: false)
        }
    }

    @MainActor
    private func openHistoryTrack(_ track: HistoryTrack, autoplay: Bool) {
        historyAudioPlayer.stop(releaseSession: true)
        do {
            try player.load(track: track.localTrack)
            hasUsedStudio = true
            selectedTab = .studio
            if autoplay { try player.play() }
        } catch {
            player.alertMessage = error.localizedDescription
            selectedTab = .studio
        }
    }

    @MainActor
    private func recordAgain(_ recording: HistoryRecording) {
        guard let sourceTrackID = recording.sourceTrackID,
              let track = history.track(withID: sourceTrackID) else {
            history.errorMessage = "The separated song used for this performance is no longer available."
            return
        }
        startRecording(track)
    }

    @MainActor
    private func startRecording(_ track: HistoryTrack) {
        historyAudioPlayer.stop(releaseSession: true)
        do {
            try player.load(track: track.localTrack)
            hasUsedStudio = true
            selectedTab = .studio
            Task { await player.toggleRecording() }
        } catch {
            player.alertMessage = error.localizedDescription
            selectedTab = .studio
        }
    }

    @MainActor
    private func separateLibrarySource(
        _ source: LibrarySeparationSource,
        using separationModel: SeparationModelKind
    ) {
        historyAudioPlayer.stop(releaseSession: true)
        model.selectedModel = separationModel
        selectedTab = .studio
        separationTask?.cancel()
        separationTask = Task { @MainActor in
            defer { separationTask = nil }
            let result: SeparationResult?
            switch source {
            case .original(let original):
                result = await model.separate(
                    original: original,
                    using: separationModel,
                    force: true
                )
            case .track(let historyTrack):
                guard let sourceURL = historyTrack.sourceURL else {
                    model.errorMessage = "The original source is unavailable for this separation."
                    return
                }
                result = await model.separate(
                    youtubeURL: sourceURL.absoluteString,
                    force: true
                )
            }
            guard let result else { return }
            do {
                try player.load(track: result.track)
                hasUsedStudio = true
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(.indigo)
            Text("Your song, your part")
                .font(.title2.bold())
            Text("Separate a track, turn down any instrument, and play along.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Separate a song", systemImage: "link")
                .font(.headline)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        urlField
                        pasteButton
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                } else {
                    HStack(spacing: 8) {
                        urlField
                        pasteButton
                    }
                }
            }
            if let urlValidationMessage {
                Label(urlValidationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Paste a YouTube video link to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            modelPicker
            Button {
                if let existingSeparation {
                    openExistingSeparation(existingSeparation)
                } else {
                    requestSeparation(force: false)
                }
            } label: {
                Label(
                    existingSeparation == nil
                        ? "Create \(model.selectedModel.stems.count) stems"
                        : "Open Existing \(model.selectedModel.stems.count)-Stem Mix",
                    systemImage: existingSeparation == nil ? "wand.and.stars" : "bolt.fill"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                YouTubeSource.validatedURL(from: youtubeURL) == nil
                    || model.isWorking
                    || !model.selectedModel.isAvailableOnCurrentDevice
            )
            if existingSeparation != nil {
                Button("Separate Again") {
                    requestSeparation(force: true)
                }
                .frame(maxWidth: .infinity)
                .disabled(model.isWorking)
                .accessibilityHint("Runs the same separation again instead of opening saved stems")
            }
        }
        .cardStyle()
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(SeparationModelKind.allCases) { separationModel in
                        Button {
                            model.selectedModel = separationModel
                        } label: {
                            Label(
                                separationModel.choiceTitle,
                                systemImage: model.selectedModel == separationModel
                                    ? "checkmark"
                                    : "circle"
                            )
                        }
                        .disabled(!separationModel.isAvailableOnCurrentDevice)
                    }
                } label: {
                    HStack {
                        Text(model.selectedModel.shortChoiceTitle)
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)
            } else {
                Picker("Separation style", selection: $model.selectedModel) {
                    ForEach(SeparationModelKind.allCases) { separationModel in
                        Text(modelChoiceLabel(separationModel))
                            .tag(separationModel)
                            .disabled(!separationModel.isAvailableOnCurrentDevice)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isWorking)
            }
            Text(
                [
                    model.selectedModel.recommendationLabel,
                    model.selectedModel.title,
                    model.selectedModel.performanceHint
                ]
                .compactMap { $0 }
                .joined(separator: " · ")
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.selectedModel.stemSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Supported stems: \(model.selectedModel.stemSummary)")
            if let message = model.selectedModel.unavailabilityMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !ModelAssetStore.isInstalled(model.selectedModel) {
                Text("Downloads \(model.selectedModel.downloadSize ?? "once") once when first used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let existingSeparation {
                Label(
                    "Already separated with \(existingSeparation.separationModel.title) \(existingSeparation.createdAt.formatted(.relative(presentation: .named))).",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else if !existingModels.isEmpty {
                Text(
                    "Saved with \(existingModels.map(\.title).joined(separator: ", ")). Select that style to open it instantly."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var urlField: some View {
        TextField("Paste a YouTube URL", text: $youtubeURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("YouTube URL")
    }

    private var pasteButton: some View {
        Button("Paste") {
            if let value = UIPasteboard.general.string {
                youtubeURL = value
            }
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Pastes a YouTube link from the clipboard")
    }

    private func modelChoiceLabel(_ separationModel: SeparationModelKind) -> String {
        guard separationModel.isAvailableOnCurrentDevice else {
            return "\(separationModel.choiceTitle) — unavailable"
        }
        guard !ModelAssetStore.isInstalled(separationModel),
              let downloadSize = separationModel.downloadSize else {
            return separationModel.choiceTitle
        }
        return "\(separationModel.choiceTitle) · \(downloadSize)"
    }

    private var progressCard: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progress)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusText).font(.subheadline.weight(.medium))
                    Text("Keep Atarang open while it works")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(model.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text(
                    model.estimatedRemainingText
                        ?? "This can take several minutes on older devices."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    separationTask?.cancel()
                    separationTask = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var mixer: some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text(player.title)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text("\(player.activeStems.count)-stem mix · \(player.separationModel.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 3) {
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(time(player.position)) of \(time(player.duration))")
                HStack {
                    Text(time(player.position))
                    Spacer()
                    Text("−\(time(max(0, player.duration - player.position)))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            recordingStatus
            recordingMixControls

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Stem Mix", systemImage: "music.note.list")
                        .font(.subheadline.weight(.semibold))
                    Text("Levels are saved for this song.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Full Mix") {
                        player.applyPracticePreset(.fullMix)
                    }
                    Button("Without Vocals") {
                        player.applyPracticePreset(.withoutVocals)
                    }
                    Button("Vocals Only") {
                        player.applyPracticePreset(.vocalsOnly)
                    }
                    Divider()
                    Button("Reset All Levels") {
                        player.resetMix()
                    }
                } label: {
                    Label("Presets", systemImage: "slider.horizontal.2.square")
                }
                .disabled(player.isRecording)
            }

            LazyVGrid(columns: stemColumns, spacing: 9) {
                ForEach(player.activeStems) { stem in
                    StemRow(
                        stem: stem,
                        volume: Binding(
                            get: { player.volume(for: stem) },
                            set: { player.setVolume($0, for: stem) }
                        ),
                        isSoloed: player.soloedStem == stem,
                        toggleMute: { player.toggleMute(for: stem) },
                        toggleSolo: { player.toggleSolo(for: stem) }
                    )
                }
            }

            if player.isExporting {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing shareable M4A…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if player.shareURL != nil {
                Button {
                    if let url = player.shareURL {
                        sharePayload = SharePayload(items: [url])
                    }
                } label: {
                    Label("Share Performance", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var mixerHeader: some View {
        HStack {
            Text("Atarang")
                .font(.largeTitle.bold())
            Spacer()
            Button {
                chooseAnotherSong()
            } label: {
                Label("New Song", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.indigo)
            .disabled(player.isRecording)
            .accessibilityLabel("New Song")
        }
    }

    private var stemColumns: [GridItem] {
        if horizontalSizeClass == .regular, !dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
        }
        return [GridItem(.flexible())]
    }

    private func chooseAnotherSong() {
        player.unload()
        youtubeURL = ""
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var playerErrorIsPresented: Binding<Bool> {
        Binding(get: { player.alertMessage != nil }, set: { if !$0 { player.alertMessage = nil } })
    }

    private var compactTransport: some View {
        HStack(spacing: 14) {
            Button {
                player.togglePlayback()
            } label: {
                Label(
                    player.isPlaying ? "Pause" : "Play",
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(TransportLabelStyle(color: .indigo))
            }
            .buttonStyle(.plain)
            .disabled(player.isRecording)
            .opacity(player.isRecording ? 0.45 : 1)

            Button {
                requestRecording()
            } label: {
                Label(
                    player.isRecording ? "Stop" : "Record",
                    systemImage: player.isRecording ? "stop.fill" : "record.circle"
                )
                .labelStyle(
                    TransportLabelStyle(
                        color: .red,
                        isActive: player.isRecording
                    )
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(player.isRecording ? "Recording" : player.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(
                    player.isRecording
                        ? time(player.recordingDuration)
                        : "\(time(player.position)) / \(time(player.duration))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(player.isRecording ? .red : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func requestRecording() {
        if player.isRecording {
            Task { await player.toggleRecording() }
        } else if didExplainRecording {
            Task { await player.toggleRecording() }
        } else {
            showsRecordingIntroduction = true
        }
    }

    @ViewBuilder
    private var recordingStatus: some View {
        if player.isRecording {
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Recording \(time(player.recordingDuration))")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.red)
            if player.isEchoCancellationActive {
                Label("Speaker bleed reduction on", systemImage: "waveform.and.mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Recording continues if you lock your device or leave Atarang.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text("Use headphones for a clean recording without speaker bleed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var recordingMixControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Recording Mix", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if player.isRecording {
                    Label("Locked", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RecordingLevelRow(
                title: "Mic",
                systemImage: "mic.fill",
                color: .red,
                value: $player.recordingMicrophoneLevel,
                range: 0...2,
                accessibilityLabel: "Microphone recording level"
            )
            .disabled(player.isRecording)

            if player.isRecording {
                MicrophoneMeter(level: player.microphoneMeterLevel)
                    .accessibilityLabel("Live microphone input")
                    .accessibilityValue(microphoneLevelDescription)
            }

            RecordingLevelRow(
                title: "Backing",
                systemImage: "waveform",
                color: .indigo,
                value: $player.recordingBackingLevel,
                range: 0...1,
                accessibilityLabel: "Backing recording level"
            )
            .disabled(player.isRecording)
        }
        .padding(11)
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    private var microphoneLevelDescription: String {
        switch player.microphoneMeterLevel {
        case ..<0.2: "Very low"
        case ..<0.55: "Good"
        case ..<0.85: "Strong"
        default: "Very loud"
        }
    }

    private var urlValidationMessage: String? {
        let trimmed = youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return YouTubeSource.validatedURL(from: trimmed) == nil
            ? "Enter a valid youtube.com or youtu.be video link."
            : nil
    }

    private func refreshExistingSeparation() {
        existingLookupTask?.cancel()
        let lookupURL = youtubeURL
        let lookupModel = model.selectedModel
        existingLookupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            existingSeparation = model.existingSeparation(
                youtubeURL: lookupURL,
                using: lookupModel
            )
            existingModels = model.existingSeparationModels(
                youtubeURL: lookupURL
            )
        }
    }

    private func requestSeparation(force: Bool) {
        guard YouTubeSource.validatedURL(from: youtubeURL) != nil else { return }
        if !ModelAssetStore.isInstalled(model.selectedModel),
           model.selectedModel.downloadSize != nil {
            pendingModelDownload = ModelDownloadRequest(force: force)
        } else {
            startSeparation(force: force)
        }
    }

    private func handleIncomingURL(_ incomingURL: URL) {
        let candidate: String?
        if incomingURL.scheme?.lowercased() == "atarang" {
            candidate = URLComponents(
                url: incomingURL,
                resolvingAgainstBaseURL: false
            )?.queryItems?.first(where: { $0.name == "url" })?.value
        } else {
            candidate = incomingURL.absoluteString
        }
        guard let candidate,
              YouTubeSource.validatedURL(from: candidate) != nil else {
            model.errorMessage = "The shared item does not contain a valid YouTube video link."
            return
        }
        if player.isLoaded { player.unload() }
        youtubeURL = candidate
        selectedTab = .studio
        studioNotice = "YouTube link received. Choose a separation style to continue."
    }

    private func consumePendingImport() {
        guard let value = UserDefaults.standard.string(
            forKey: PendingYouTubeImport.defaultsKey
        ) else { return }
        UserDefaults.standard.removeObject(
            forKey: PendingYouTubeImport.defaultsKey
        )
        if let url = URL(string: value) {
            handleIncomingURL(url)
        }
    }

    private func startSeparation(force: Bool) {
        separationTask?.cancel()
        separationTask = Task { @MainActor in
            await separate(youtubeURL, force: force)
            separationTask = nil
        }
    }

    private func openExistingSeparation(_ track: LocalTrack) {
        do {
            try player.load(track: track)
            hasUsedStudio = true
            studioNotice = "Opened a saved separation instantly."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func separate(_ url: String, force: Bool) async {
        if let result = await model.separate(youtubeURL: url, force: force) {
            do {
                try player.load(track: result.track)
                hasUsedStudio = true
                studioNotice = result.reusedExistingSeparation
                    ? "Opened a saved separation instantly."
                    : "Separation ready to mix."
                refreshExistingSeparation()
                await runDebugRecordingIfRequested()
            }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline)
            Spacer()
            Button {
                studioNotice = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    @MainActor
    private func runDebugRecordingIfRequested() async {
        guard let rawSeconds = ProcessInfo.processInfo.environment["ATARANG_DEBUG_RECORD_SECONDS"],
              let seconds = Double(rawSeconds), seconds > 0 else { return }
        await player.toggleRecording()
        guard player.isRecording else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard player.isRecording else { return }
            await player.toggleRecording()
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum AppTab {
    case studio, history
}

private struct ModelDownloadRequest: Identifiable {
    let id = UUID()
    let force: Bool
}

private struct StemRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let stem: StemKind
    @Binding var volume: Float
    let isSoloed: Bool
    let toggleMute: () -> Void
    let toggleSolo: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    levelSlider
                    HStack {
                        Spacer()
                        muteButton
                        soloButton
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: stem.icon)
                        .frame(width: 25)
                        .foregroundStyle(stem.color)
                    VStack(alignment: .leading, spacing: 4) {
                        header
                        levelSlider
                    }
                    muteButton
                    soloButton
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var header: some View {
        HStack {
            if dynamicTypeSize.isAccessibilitySize {
                Image(systemName: stem.icon)
                    .foregroundStyle(stem.color)
            }
            Text(stem.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text("\(Int(volume * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var levelSlider: some View {
        Slider(value: $volume, in: 0...1)
            .tint(stem.color)
            .accessibilityLabel("\(stem.title) level")
            .accessibilityValue("\(Int(volume * 100)) percent")
    }

    private var muteButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .frame(minWidth: 38, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(volume == 0 ? .secondary : stem.color)
        .accessibilityLabel(volume == 0 ? "Unmute \(stem.title)" : "Mute \(stem.title)")
    }

    private var soloButton: some View {
        Button(action: toggleSolo) {
            Text("S")
                .font(.caption.weight(.bold))
                .frame(minWidth: 22, minHeight: 22)
        }
        .buttonStyle(.borderedProminent)
        .tint(isSoloed ? stem.color : .secondary.opacity(0.35))
        .accessibilityLabel(isSoloed ? "Turn off solo for \(stem.title)" : "Solo \(stem.title)")
    }
}

private struct RecordingLevelRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let systemImage: String
    let color: Color
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accessibilityLabel: String

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    labelAndValue
                    slider
                }
            } else {
                HStack(spacing: 12) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(color)
                        .frame(minWidth: 76, alignment: .leading)
                    slider
                    Text("\(percentage)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var labelAndValue: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
            Spacer()
            Text("\(percentage)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var slider: some View {
        Slider(value: $value, in: range, step: 0.05)
            .tint(color)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue("\(percentage) percent")
    }

    private var percentage: Int {
        Int((value * 100).rounded())
    }
}

private struct TransportLabelStyle: LabelStyle {
    let color: Color
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon
                .font(.headline)
                .frame(width: 48, height: 38)
                .background(isActive ? color : color.opacity(0.14), in: Capsule())
                .foregroundStyle(isActive ? .white : color)
            configuration.title
                .font(.caption2.weight(.semibold))
        }
    }
}

private struct RecordingIntroductionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let continueRecording: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Label("Record your performance", systemImage: "mic.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text(
                    "Atarang records your microphone together with the backing mix. The recording stays on this device unless you share it."
                )
                Label("Use headphones for the cleanest recording.", systemImage: "headphones")
                Label("Recording can continue while the screen is locked.", systemImage: "lock")
                Spacer()
                Button {
                    continueRecording()
                } label: {
                    Label("Continue", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Not Now") { dismiss() }
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Before You Record")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct MicrophoneMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text("Input")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.16))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * CGFloat(level))
                }
            }
            .frame(height: 7)
        }
    }

    private var meterColor: Color {
        switch level {
        case ..<0.55: .green
        case ..<0.85: .yellow
        default: .red
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview { ContentView() }
