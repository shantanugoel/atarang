import SwiftUI

struct ContentView: View {
    @StateObject private var model = SeparationModel()
    @StateObject private var player = StemPlayer()
    @StateObject private var history = HistoryStore()
    @StateObject private var historyAudioPlayer = HistoryAudioPlayer()
    @State private var youtubeURL: String
    @State private var didRunDebugURL = false
    @State private var sharePayload: SharePayload?
    @State private var selectedTab = AppTab.studio
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
                        if !player.isLoaded { hero }
                        if player.isLoaded {
                            mixerHeader
                            mixer
                        } else {
                            importCard
                        }
                        if model.isWorking { progressCard }
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Atarang")
                .navigationBarTitleDisplayMode(.large)
                .toolbar(player.isLoaded ? .hidden : .visible, for: .navigationBar)
                .alert("Couldn’t separate this song", isPresented: errorIsPresented) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "Unknown error")
                }
                .alert("Audio problem", isPresented: playerErrorIsPresented) {
                    Button("OK") { player.alertMessage = nil }
                } message: {
                    Text(player.alertMessage ?? "Unknown audio error")
                }
                .sheet(item: $sharePayload) { payload in
                    ActivityView(items: payload.items)
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
                separateSource: separateLibrarySource
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
        .task {
            guard !didRunDebugURL, let debugURL, !debugURL.isEmpty else { return }
            didRunDebugURL = true
            await separate(debugURL)
        }
    }

    @MainActor
    private func openHistoryTrack(_ track: HistoryTrack, autoplay: Bool) {
        historyAudioPlayer.stop(releaseSession: true)
        do {
            try player.load(track: track.localTrack)
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
        Task { @MainActor in
            let track: LocalTrack?
            switch source {
            case .original(let original):
                track = await model.separate(
                    original: original,
                    using: separationModel
                )
            case .track(let historyTrack):
                guard let sourceURL = historyTrack.sourceURL else {
                    model.errorMessage = "The original source is unavailable for this separation."
                    return
                }
                track = await model.separate(youtubeURL: sourceURL.absoluteString)
            }
            guard let track else { return }
            do {
                try player.load(track: track)
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
            TextField("Paste a YouTube URL", text: $youtubeURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            modelPicker
            Button {
                Task { await separate(youtubeURL) }
            } label: {
                Label("Create \(model.selectedModel.stems.count) stems", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isWorking
            )
        }
        .cardStyle()
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Separation model", selection: $model.selectedModel) {
                ForEach(SeparationModelKind.allCases) { separationModel in
                    Text(ModelAssetStore.isInstalled(separationModel)
                        ? separationModel.title
                        : "\(separationModel.title) — downloads once"
                    )
                    .tag(separationModel)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isWorking)
            Text(model.selectedModel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(model.selectedModel.stemSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Supported stems: \(model.selectedModel.stemSummary)")
            if !ModelAssetStore.isInstalled(model.selectedModel) {
                Text("Downloads once when first used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
        }
        .cardStyle()
    }

    private var mixer: some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text(player.title).font(.headline).lineLimit(1)
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

            HStack(spacing: 34) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.indigo, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(player.isRecording)
                .opacity(player.isRecording ? 0.45 : 1)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    Task { await player.toggleRecording() }
                } label: {
                    Image(systemName: player.isRecording ? "stop.fill" : "record.circle")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(player.isRecording ? Color.red : Color.red.opacity(0.14), in: Circle())
                        .foregroundStyle(player.isRecording ? .white : .red)
                }
                .accessibilityLabel(player.isRecording ? "Stop recording" : "Record performance")
            }

            recordingStatus
            recordingMixControls

            VStack(spacing: 9) {
                ForEach(player.activeStems) { stem in
                    StemRow(stem: stem, volume: Binding(
                        get: { player.volume(for: stem) },
                        set: { player.setVolume($0, for: stem) }
                    ))
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
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.indigo)
            .disabled(player.isRecording)
            .accessibilityLabel("New Song")
        }
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
            Text("Recording continues if you lock your iPhone or leave Atarang.")
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

    @MainActor
    private func separate(_ url: String) async {
        if let track = await model.separate(youtubeURL: url) {
            do {
                try player.load(track: track)
                await runDebugRecordingIfRequested()
            }
            catch { model.errorMessage = error.localizedDescription }
        }
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

private struct StemRow: View {
    let stem: StemKind
    @Binding var volume: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stem.icon)
                .frame(width: 25)
                .foregroundStyle(stem.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stem.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $volume, in: 0...1)
                    .tint(stem.color)
                    .accessibilityLabel("\(stem.title) level")
                    .accessibilityValue("\(Int(volume * 100)) percent")
            }
            Button {
                volume = volume == 0 ? 1 : 0
            } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(volume == 0 ? .secondary : stem.color)
            .accessibilityLabel(volume == 0 ? "Unmute \(stem.title)" : "Mute \(stem.title)")
        }
    }
}

private struct RecordingLevelRow: View {
    let title: String
    let systemImage: String
    let color: Color
    @Binding var value: Float
    let range: ClosedRange<Float>
    let accessibilityLabel: String

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 88, alignment: .leading)
            Slider(value: $value, in: range, step: 0.05)
                .tint(color)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("\(percentage) percent")
            Text("\(percentage)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var percentage: Int {
        Int((value * 100).rounded())
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
