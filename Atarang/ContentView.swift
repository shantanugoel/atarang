import SwiftUI

struct ContentView: View {
    @StateObject private var model = SeparationModel()
    @StateObject private var player = StemPlayer()
    @StateObject private var history = HistoryStore()
    @StateObject private var historyAudioPlayer = HistoryAudioPlayer()
    @State private var youtubeURL: String
    @State private var didRunDebugURL = false
    @State private var showingShareSheet = false
    @State private var selectedTab = AppTab.mixer
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
                        hero
                        if player.isLoaded { mixer } else { importCard }
                        if model.isWorking { progressCard }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Atarang")
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
                .sheet(isPresented: $showingShareSheet) {
                    if let url = player.shareURL {
                        ActivityView(items: [url])
                            .presentationDetents([.medium, .large])
                    }
                }
            }
            .tabItem { Label("Play", systemImage: "waveform.badge.mic") }
            .tag(AppTab.mixer)

            HistoryView(
                store: history,
                audioPlayer: historyAudioPlayer,
                audioPlaybackDisabled: player.isRecording,
                openTrack: openHistoryTrack,
                recordTrack: startRecording,
                recordAgain: recordAgain
            )
            .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.history)
        }
        .tint(.indigo)
        .onReceive(NotificationCenter.default.publisher(for: .atarangLibraryDidChange)) { _ in
            history.refresh()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history, player.isPlaying, !player.isRecording {
                player.pause()
            } else if tab == .mixer {
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
        historyAudioPlayer.stop()
        do {
            try player.load(track: track.localTrack)
            selectedTab = .mixer
            if autoplay { try player.play() }
        } catch {
            player.alertMessage = error.localizedDescription
            selectedTab = .mixer
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
        historyAudioPlayer.stop()
        do {
            try player.load(track: track.localTrack)
            selectedTab = .mixer
            Task { await player.toggleRecording() }
        } catch {
            player.alertMessage = error.localizedDescription
            selectedTab = .mixer
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
            Button {
                Task { await separate(youtubeURL) }
            } label: {
                Label("Create four stems", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(youtubeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
        }
        .cardStyle()
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
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(player.title).font(.headline).lineLimit(2)
                Text("4-stem mix").font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 5) {
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 0.01))
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
                        .frame(width: 62, height: 62)
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
                        .frame(width: 62, height: 62)
                        .background(player.isRecording ? Color.red : Color.red.opacity(0.14), in: Circle())
                        .foregroundStyle(player.isRecording ? .white : .red)
                }
                .accessibilityLabel(player.isRecording ? "Stop recording" : "Record performance")
            }

            recordingStatus

            VStack(spacing: 14) {
                ForEach(StemKind.allCases) { stem in
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
                    showingShareSheet = true
                } label: {
                    Label("Share recorded performance", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Choose another song", systemImage: "arrow.triangle.2.circlepath") {
                player.unload()
                youtubeURL = ""
            }
            .font(.subheadline)
        }
        .cardStyle()
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
            Text("Recording and playback continue with the screen locked or Atarang in the background.")
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
    case mixer, history
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

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

#Preview { ContentView() }
