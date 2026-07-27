import SwiftUI

/// The part of Studio that is about the *song*: what you read while playing.
///
/// Mixer and Lyrics are real. Chords and Sheet ship as empty states because the
/// selector is the shape of the screen — adding stages one phase at a time
/// would mean rebuilding the layout around them, and an honest "not yet, here
/// is what it will do" is better than a stage that appears from nowhere in a
/// later release.
struct StageContainer: View {
    let player: StemPlayer
    let lyrics: LyricsStore
    /// Regular width puts the tools beside the Stage, so the Stage should not
    /// also try to fill the screen.
    var showsSelector = true
    var openSingAlong: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if showsSelector {
                Picker(
                    "Stage",
                    selection: Binding(
                        get: { player.practiceSettings.stage },
                        set: { player.setStage($0) }
                    )
                ) {
                    ForEach(StudioStage.allCases) { stage in
                        Text(stage.title).tag(stage)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .accessibilityHint("Changes what the stage shows without stopping playback")
            }

            TabView(
                selection: Binding(
                    get: { player.practiceSettings.stage },
                    set: { player.setStage($0) }
                )
            ) {
                ForEach(StudioStage.allCases) { stage in
                    stageContent(stage)
                        .tag(stage)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    @ViewBuilder
    private func stageContent(_ stage: StudioStage) -> some View {
        switch stage {
        case .mixer:
            MixerStage(player: player)
        case .lyrics:
            LyricsStage(
                player: player,
                store: lyrics,
                openSingAlong: openSingAlong
            )
        case .chords:
            StagePlaceholder(
                stage: .chords,
                headline: "Chords",
                detail: "A bar grid that follows the playhead, transposed to match the key you are playing in.",
                availability: "Arrives with the chords milestone."
            )
        case .sheet:
            StagePlaceholder(
                stage: .sheet,
                headline: "Sheet",
                detail: "Chord symbols placed over the lyric they land on, sized to read at arm's length.",
                availability: "Arrives once lyrics and chords are both in place."
            )
        }
    }
}

/// The stem mixer, moved across from the old Mix workspace unchanged apart from
/// losing the recording levels and the position slider, which now live in
/// Settings and the transport.
struct MixerStage: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let player: StemPlayer

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
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
                        Button("Full Mix") { player.applyPracticePreset(.fullMix) }
                        Button("Without Vocals") { player.applyPracticePreset(.withoutVocals) }
                        Button("Vocals Only") { player.applyPracticePreset(.vocalsOnly) }
                        Divider()
                        Button("Reset All Levels") { player.resetMix() }
                    } label: {
                        Label("Presets", systemImage: "slider.horizontal.2.square")
                            .frame(minHeight: 44)
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

                Text("\(player.activeStems.count)-stem mix · \(player.separationModel.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var stemColumns: [GridItem] {
        if horizontalSizeClass == .regular, !dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
        }
        return [GridItem(.flexible())]
    }
}

struct StagePlaceholder: View {
    let stage: StudioStage
    let headline: String
    let detail: String
    let availability: String

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: stage.icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(headline)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(availability)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 420)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(detail) \(availability)")
    }
}

struct StemRow: View {
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
            Text(StudioFormat.percent(volume))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    private var levelSlider: some View {
        Slider(value: $volume, in: 0...1)
            .tint(stem.color)
            .accessibilityLabel("\(stem.title) level")
            .accessibilityValue(StudioFormat.percent(volume))
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
