import SwiftUI
import UIKit

/// The app shell, and the coordinator for Studio.
///
/// Studio is one screen now — transport, Stage, chips — rather than a Mix and
/// Practice pair. This file owns the objects, the navigation, and the wiring
/// between them; every piece of the layout lives in its own file
/// (`TransportBar`, `StageContainer`, `ToolChipRow`, `ImportView`,
/// `RecordingMode`, `SettingsView`).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didExplainRecording") private var didExplainRecording = false
    @AppStorage("hasUsedStudio") private var hasUsedStudio = false
    @StateObject private var model = SeparationModel()
    @State private var player = StemPlayer()
    @StateObject private var history = HistoryStore()
    @StateObject private var historyAudioPlayer = HistoryAudioPlayer()
    @StateObject private var takePreviewPlayer = RecordingMixPreviewPlayer()
    @State private var youtubeURL: String
    @State private var didRunDebugURL = false
    @State private var sharePayload: SharePayload?
    @State private var selectedTab = AppTab.studio
    @State private var separationTask: Task<Void, Never>?
    @State private var pendingModelDownload: ModelDownloadRequest?
    @State private var studioNotice: StudioNotice?
    @State private var showsRecordingIntroduction = false
    @State private var selectedTool: StudioTool?
    /// The split layouts show a tool in place instead of presenting it, so the
    /// selection has to outlive the sheet's.
    @State private var inspectorTool: StudioTool? = .loop
    /// The track the player has open, kept so the toolbar can act on its
    /// source and the transport can draw its waveform.
    @State private var loadedTrack: LocalTrack?
    @State private var waveform: WaveformSummary?
    private let debugURL: String?

    /// Long-running work reports itself in one place, whoever started it.
    private var analysis: AnalysisProgressCenter { .shared }

    init() {
        let value = ProcessInfo.processInfo.environment["ATARANG_DEBUG_URL"]
        debugURL = value
        _youtubeURL = State(initialValue: value ?? "")
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            studioTab
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
                createFirstSeparation: { selectedTab = .studio }
            )
            .tabItem { Label("Library", systemImage: "music.note.house") }
            .tag(AppTab.history)

            SettingsView(player: player, separationModel: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .background(KeyboardDismissController())
        .tint(.indigo)
        .onChange(of: selectedTab) { _, tab in
            if tab != .studio, !player.isRecording {
                player.suspend()
                takePreviewPlayer.stop(releaseSession: true)
            }
            if tab != .history {
                historyAudioPlayer.stop()
            }
        }
        .onChange(of: shouldKeepScreenAwake, initial: true) { _, keepAwake in
            UIApplication.shared.isIdleTimerDisabled = keepAwake
        }
        .onChange(of: scenePhase) { _, phase in
            player.logDiagnosticEvent(
                "scenePhase",
                detail: "phase=\(phase) isPlaying=\(player.isPlaying)"
            )
            // The throttled practice writes must land before the app can be
            // suspended or killed in the background.
            if phase != .active { player.flushPracticeSettings() }
            if phase == .background { UIApplication.shared.isIdleTimerDisabled = false }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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

    // MARK: - Studio

    private var studioTab: some View {
        NavigationStack {
            Group {
                if player.isLoaded {
                    loadedStudio
                } else {
                    importScreen
                }
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if player.isLoaded { transportInset }
            }
            .navigationTitle(player.isLoaded ? player.title : "Atarang")
            .navigationBarTitleDisplayMode(player.isLoaded ? .inline : .large)
            .toolbar { studioToolbar }
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
                        "\(model.selectedModel.outcomeTitle) is downloaded once and kept on this device. Separation begins after the download finishes."
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
            .sheet(item: $selectedTool) { tool in
                ToolSheet(tool: tool, player: player)
                    .presentationDetents([.medium, .large])
            }
            // A confirmation the user has already read stops being a
            // confirmation and starts being clutter. A caution is not on the
            // same footing: it says something changed that the user did not
            // ask for, and it stays until they dismiss it or open another song.
            .task(id: studioNotice) {
                guard studioNotice?.kind == .confirmation else { return }
                try? await Task.sleep(for: .seconds(5))
                studioNotice = nil
            }
        }
    }

    /// Portrait stacks Stage over transport. Anywhere with width to spare —
    /// iPad, and an iPhone on its side — puts the tools beside the Stage
    /// instead, since a sheet there would cover nothing to reveal nothing.
    @ViewBuilder
    private var loadedStudio: some View {
        VStack(spacing: 0) {
            if let studioNotice { noticeBanner(studioNotice) }
            if usesSplitLayout {
                HStack(spacing: 0) {
                    StageContainer(player: player)
                    Divider()
                    ToolInspector(
                        player: player,
                        tool: $inspectorTool,
                        // In landscape the chips are already in the transport,
                        // and they are what drives this pane.
                        showsChips: !isLandscapePhone
                    )
                    .frame(width: isLandscapePhone ? 320 : 340)
                }
            } else {
                StageContainer(player: player)
            }
        }
    }

    private var isRegularWidth: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    /// An iPhone on its side: wide, and short enough that a separate chip band
    /// above the transport would cost a third of the height.
    private var isLandscapePhone: Bool {
        verticalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize
    }

    private var usesSplitLayout: Bool { isRegularWidth || isLandscapePhone }

    private var foldsChipsIntoTransport: Bool { isLandscapePhone }

    private var transportInset: some View {
        VStack(spacing: 8) {
            if let take = player.recordedTake, !player.isRecording {
                TakeComparisonStrip(
                    player: player,
                    isPreviewPlaying: takePreviewPlayer.isPlaying,
                    playReference: {
                        takePreviewPlayer.stop(releaseSession: true)
                        player.seek(to: player.loopRange?.start ?? 0)
                        player.requestPlayback()
                    },
                    toggleTake: { toggleTakePreview(take) }
                )
            }
            if !usesSplitLayout {
                ToolChipRow(player: player, selectedTool: $selectedTool)
            }
            TransportBar(
                player: player,
                waveform: waveform,
                requestRecording: requestRecording,
                // Folded chips select what the inspector beside the Stage
                // shows, rather than presenting a sheet over it.
                foldedChips: foldsChipsIntoTransport
                    ? AnyView(ToolChipRow(player: player, selectedTool: $inspectorTool))
                    : nil
            )
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var studioToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if player.isLoaded {
                    Button {
                        chooseAnotherSong()
                    } label: {
                        Label("New Song", systemImage: "plus")
                    }
                    .disabled(player.isRecording)

                    exportMenuItems

                    if let source = loadedTrack?.sourceURL {
                        Button {
                            separateAgain(source)
                        } label: {
                            Label("Separate Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(player.isRecording || analysis.isBusy)
                    }

                    Divider()
                    Button(role: .destructive) {
                        player.resetPracticeSettings()
                    } label: {
                        Label("Reset Practice Settings", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(player.isRecording)
                } else {
                    Button {
                        selectedTab = .history
                    } label: {
                        Label("Open Library", systemImage: "music.note.house")
                    }
                }
            } label: {
                Label("Song actions", systemImage: "ellipsis.circle")
            }
            .accessibilityLabel("Song actions")
        }
    }

    /// The export belongs to the recording, not to this screen: it keeps
    /// running if the user loads another song and finishes into the Library.
    /// Studio shows it only while that same take is still loaded here.
    @ViewBuilder
    private var exportMenuItems: some View {
        if let take = player.recordedTake,
           let status = RecordingExportCenter.shared.status(for: take.id) {
            switch status {
            case .running:
                Button {} label: {
                    Label("Preparing Shareable Mix…", systemImage: "hourglass")
                }
                .disabled(true)
            case .finished(let url):
                Button {
                    sharePayload = SharePayload(items: [url])
                } label: {
                    Label("Share Performance", systemImage: "square.and.arrow.up")
                }
            case .failed:
                Button {
                    RecordingExportCenter.shared.retry(take.id)
                } label: {
                    Label("Retry Shareable Mix", systemImage: "exclamationmark.arrow.circlepath")
                }
            }
        }
    }

    private var importScreen: some View {
        ScrollView {
            VStack(spacing: 22) {
                if !hasUsedStudio, !dynamicTypeSize.isAccessibilitySize { hero }
                if let studioNotice { noticeBanner(studioNotice) }
                ImportView(
                    youtubeURL: $youtubeURL,
                    selectedModel: $model.selectedModel,
                    isBusy: analysis.isBusy,
                    existingSeparation: existingSeparation,
                    existingModels: existingModels,
                    separate: { requestSeparation(force: false) },
                    separateAgain: { requestSeparation(force: true) },
                    openExisting: openExistingSeparation
                )
                if let job = analysis.active { progressCard(job) }
            }
            .padding()
            .frame(maxWidth: horizontalSizeClass == .regular ? 760 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
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

    private func progressCard(_ job: AnalysisProgressCenter.Job) -> some View {
        VStack(spacing: 12) {
            if job.isWaiting {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView(value: job.progress)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.status).font(.subheadline.weight(.medium))
                    Text("Keep Atarang open while it works")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !job.isWaiting {
                    Text("\(Int(job.progress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(
                    job.estimatedRemainingText
                        ?? "This can take several minutes on older devices."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { analysis.cancelActive() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private func noticeBanner(_ notice: StudioNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.iconName)
                .foregroundStyle(notice.tint)
            Text(notice.text)
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
        .background(notice.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    // MARK: - Playback lifecycle

    /// Playing along with an instrument means long stretches without touching
    /// the screen, and the auto-lock cutting the song off mid-practice is the
    /// worst moment for it to happen. Scoped to Studio actually running
    /// something, so a paused song or another tab still lets the screen sleep.
    /// Phase 6's full-screen sing-along mode extends this rather than
    /// replacing it.
    private var shouldKeepScreenAwake: Bool {
        selectedTab == .studio
            && player.isLoaded
            && (player.isPlaying || player.isRecording || player.isCountingIn)
    }

    @MainActor
    private func load(_ track: LocalTrack) throws {
        try player.load(track: track)
        // Reported here rather than at the two call sites that also show a
        // confirmation, because a practice target that this separation does not
        // have has to be said whichever door the user came in through — the
        // Library, a re-separation, or a fresh one.
        studioNotice = player.takePracticeNotice().map(StudioNotice.caution)
        hasUsedStudio = true
        loadedTrack = track
        loadWaveform(for: track)
    }

    /// The overview is measured off the main actor and cached beside the stems,
    /// so it costs one pass the first time a separation is opened and nothing
    /// afterwards.
    private func loadWaveform(for track: LocalTrack) {
        waveform = nil
        Task {
            let summary = await WaveformStore.shared.summary(for: track)
            guard loadedTrack?.id == track.id else { return }
            waveform = summary
        }
    }

    @MainActor
    private func openHistoryTrack(_ track: HistoryTrack, autoplay: Bool) {
        historyAudioPlayer.stop(releaseSession: true)
        takePreviewPlayer.stop(releaseSession: true)
        do {
            try load(track.localTrack)
            selectedTab = .studio
            if autoplay { player.requestPlayback() }
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
        takePreviewPlayer.stop(releaseSession: true)
        do {
            try load(track.localTrack)
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
            do { try load(result.track) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    /// Re-runs the separation for the song that is open. The track has to be
    /// closed first — its stem files are about to be replaced — but the URL is
    /// set afterwards, since closing a song clears the field.
    private func separateAgain(_ source: URL) {
        chooseAnotherSong()
        youtubeURL = source.absoluteString
        requestSeparation(force: true)
    }

    private func toggleTakePreview(_ take: RecordedTake) {
        if takePreviewPlayer.isPlaying {
            takePreviewPlayer.stop(releaseSession: true)
        } else {
            player.suspend()
            do {
                try takePreviewPlayer.load(take: take)
                takePreviewPlayer.play()
            } catch {
                player.alertMessage = error.localizedDescription
            }
        }
    }

    private func requestRecording() {
        if player.isRecording || didExplainRecording {
            Task { await player.toggleRecording() }
        } else {
            showsRecordingIntroduction = true
        }
    }

    private func chooseAnotherSong() {
        takePreviewPlayer.stop(releaseSession: true)
        player.unload()
        loadedTrack = nil
        waveform = nil
        youtubeURL = ""
    }

    // MARK: - Separation

    private var errorIsPresented: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var playerErrorIsPresented: Binding<Bool> {
        Binding(get: { player.alertMessage != nil }, set: { if !$0 { player.alertMessage = nil } })
    }

    /// The saved separation for whatever is currently in the URL field.
    ///
    /// Answered from the published Library snapshot, so typing a URL does no
    /// file-system work at all.
    private var existingSeparation: LocalTrack? {
        guard let url = YouTubeSource.validatedURL(from: youtubeURL) else { return nil }
        return history.snapshot.separation(
            forSourceURL: url,
            using: model.selectedModel
        )
    }

    private var existingModels: [SeparationModelKind] {
        guard let url = YouTubeSource.validatedURL(from: youtubeURL) else { return [] }
        return history.snapshot.separationModels(forSourceURL: url)
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
        if player.isLoaded { chooseAnotherSong() }
        youtubeURL = candidate
        selectedTab = .studio
        studioNotice = .confirmation("YouTube link received. Choose what you want out of it to continue.")
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

    /// Confirms a song opened, unless `load` already had something more
    /// important to say. "Opened instantly" is a pleasantry; a practice target
    /// that no longer exists is something the user has to be told before they
    /// start playing along to the wrong part.
    private func announce(_ confirmation: String) {
        guard studioNotice == nil else { return }
        studioNotice = .confirmation(confirmation)
    }

    private func openExistingSeparation(_ track: LocalTrack) {
        do {
            try load(track)
            announce("Opened a saved separation instantly.")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func separate(_ url: String, force: Bool) async {
        if let result = await model.separate(youtubeURL: url, force: force) {
            do {
                try load(result.track)
                announce(
                    result.reusedExistingSeparation
                        ? "Opened a saved separation instantly."
                        : "Separation ready to play."
                )
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
}

/// A short, self-dismissing message above the Studio content.
///
/// Two kinds, because they are not the same thing: a confirmation says
/// something the user asked for happened, and a caution says something they
/// did not ask for did. A green tick on "your practice target is gone" would
/// be the interface agreeing with itself.
struct StudioNotice: Equatable {
    enum Kind: Equatable {
        case confirmation
        case caution
    }

    let kind: Kind
    let text: String

    static func confirmation(_ text: String) -> StudioNotice {
        StudioNotice(kind: .confirmation, text: text)
    }

    static func caution(_ text: String) -> StudioNotice {
        StudioNotice(kind: .caution, text: text)
    }

    var iconName: String {
        switch kind {
        case .confirmation: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .confirmation: .green
        case .caution: .orange
        }
    }
}

/// The regular-width counterpart of the chip row.
///
/// The same chips, but selecting one shows it in place instead of presenting a
/// sheet — a sheet over a screen with this much unused width would be covering
/// nothing to reveal nothing.
private struct ToolInspector: View {
    let player: StemPlayer
    @Binding var tool: StudioTool?
    /// False in landscape, where the chips live in the transport instead.
    var showsChips = true

    var body: some View {
        VStack(spacing: 0) {
            if showsChips {
                ToolChipRow(player: player, selectedTool: $tool)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                Divider()
            }
            Form { toolContent(tool ?? .loop) }
        }
        // Same rule as the chip row: one mode explanation in the transport,
        // rather than each tool going quiet on its own.
        .disabled(player.isRecording)
        .opacity(player.isRecording ? 0.4 : 1)
        .accessibilityLabel("Practice tools")
    }

    @ViewBuilder
    private func toolContent(_ tool: StudioTool) -> some View {
        switch tool {
        case .loop: LoopToolContent(player: player)
        case .speed: SpeedToolContent(player: player)
        case .key: KeyToolContent(player: player)
        case .target: TargetToolContent(player: player)
        case .click: ClickToolContent(player: player)
        case .reps: RepetitionToolContent(player: player)
        case .sections: SectionsToolContent(player: player)
        case .countIn: CountInToolContent(player: player)
        }
    }
}

private enum AppTab {
    case studio, history, settings
}

private struct ModelDownloadRequest: Identifiable {
    let id = UUID()
    let force: Bool
}

#Preview { ContentView() }
