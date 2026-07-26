import SwiftUI

/// The eight practice tools, as chips that state their own current value.
///
/// This replaces the always-expanded Practice stack, where every tool occupied
/// a full-width card whether or not it was in use, and finding the one you
/// wanted meant scrolling past the seven you did not. A chip is the tool's
/// value plus a way in; the sheet behind it holds nothing else.
enum StudioTool: String, CaseIterable, Identifiable {
    case loop, speed, key, target, click, reps, sections, countIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loop: "Loop"
        case .speed: "Speed"
        case .key: "Key"
        case .target: "Target"
        case .click: "Click"
        case .reps: "Reps"
        case .sections: "Sections"
        case .countIn: "Count-in"
        }
    }

    var icon: String {
        switch self {
        case .loop: "repeat"
        case .speed: "speedometer"
        case .key: "music.note"
        case .target: "scope"
        case .click: "metronome"
        case .reps: "arrow.triangle.2.circlepath"
        case .sections: "bookmark"
        case .countIn: "timer"
        }
    }
}

struct ToolChipRow: View {
    let player: StemPlayer
    @Binding var selectedTool: StudioTool?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(StudioTool.allCases) { tool in
                    ToolChip(
                        tool: tool,
                        value: value(for: tool),
                        isActive: isActive(tool)
                    ) {
                        selectedTool = tool
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // One explanation of the mode, rather than eight controls that quietly
        // stop responding. The strip above already says why.
        .disabled(player.isRecording)
        .opacity(player.isRecording ? 0.4 : 1)
        .accessibilityLabel("Practice tools")
    }

    private func isActive(_ tool: StudioTool) -> Bool {
        let settings = player.practiceSettings
        switch tool {
        case .loop: return settings.isLoopEnabled
        case .speed: return abs(player.playbackRate - 1) > 0.001
        case .key: return abs(player.pitchSemitones) > 0.001
        case .target: return settings.preset != .learn || player.hasCustomMix
        case .click: return settings.metronomeEnabled
        case .reps: return settings.repetitionTarget > 0 || settings.tempoRampEnabled
        case .sections: return !settings.savedSections.isEmpty
        case .countIn: return settings.countInClicks > 0
        }
    }

    private func value(for tool: StudioTool) -> String {
        let settings = player.practiceSettings
        switch tool {
        case .loop:
            guard let loop = settings.loopRange else { return "Not set" }
            return "\(StudioFormat.time(loop.start))–\(StudioFormat.time(loop.end))"
        case .speed:
            return StudioFormat.percent(player.playbackRate)
        case .key:
            return StudioFormat.semitonesShort(player.pitchSemitones)
        case .target:
            return settings.target?.title ?? "None"
        case .click:
            return settings.metronomeEnabled ? "\(settings.metronomeBPM) BPM" : "Off"
        case .reps:
            if settings.repetitionTarget == 0 {
                return settings.tempoRampEnabled ? "Ramp" : "Endless"
            }
            return "\(player.completedRepetitions)/\(settings.repetitionTarget)"
        case .sections:
            let count = settings.savedSections.count
            return count == 0 ? "None" : "\(count) saved"
        case .countIn:
            return settings.countInClicks == 0 ? "Off" : "\(settings.countInClicks) clicks"
        }
    }
}

private struct ToolChip: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let tool: StudioTool
    let value: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tool.icon)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.indigo : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(tool.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(
                isActive ? Color.indigo.opacity(0.14) : Color.primary.opacity(0.06),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.indigo.opacity(0.45) : .clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityValue(value)
        .accessibilityHint("Opens \(tool.title.lowercased()) settings")
    }
}

// MARK: - Sheets

/// One tool, one sheet, nothing else in it.
struct ToolSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: StudioTool
    let player: StemPlayer

    var body: some View {
        NavigationStack {
            Form {
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
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LoopToolContent: View {
    let player: StemPlayer

    var body: some View {
        Section {
            HStack {
                Button("Set A at Playhead") {
                    player.setLoopBoundaryA()
                    Haptics.boundarySet()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                Button("Set B at Playhead") {
                    player.setLoopBoundaryB()
                    Haptics.boundarySet()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            if let loop = player.practiceSettings.loopRange {
                nudgeRow(
                    title: "A",
                    value: loop.start,
                    color: .green,
                    nudge: { player.adjustLoopBoundaryA(by: $0) }
                )
                nudgeRow(
                    title: "B",
                    value: loop.end,
                    color: .orange,
                    nudge: { player.adjustLoopBoundaryB(by: $0) }
                )
                Toggle(
                    "Loop enabled",
                    isOn: Binding(
                        get: { player.practiceSettings.isLoopEnabled },
                        set: { player.setLoopEnabled($0) }
                    )
                )
                Button("Clear Loop", role: .destructive) { player.clearLoop() }
                    .frame(minHeight: 44)
            }
        } footer: {
            Text(
                player.practiceSettings.loopRange == nil
                    ? "Set A and B here, or tap Set A then Set B in the transport. Drag the A and B handles on the timeline to adjust. The minimum loop is \(PlaybackLoopRange.minimumDuration.formatted()) seconds."
                    : "Drag the A and B handles on the timeline for coarse changes; nudge here for fine ones."
            )
        }
    }

    /// Nudges rather than a slider. Phase 1 recorded why: B spanned the whole
    /// song, so one point of slider travel was most of a second on a four-minute
    /// track, and A's range was derived from B, which made the A knob jump
    /// whenever B moved. The timeline handles do the coarse work now.
    private func nudgeRow(
        title: String,
        value: TimeInterval,
        color: Color,
        nudge: @escaping (TimeInterval) -> Void
    ) -> some View {
        HStack {
            Text("\(title) · \(StudioFormat.preciseTime(value))")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Spacer()
            Button {
                nudge(-0.1)
                Haptics.boundarySet()
            } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            Button {
                nudge(0.1)
                Haptics.boundarySet()
            } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop boundary \(title)")
        .accessibilityValue(StudioFormat.preciseTime(value))
    }
}

struct SpeedToolContent: View {
    let player: StemPlayer

    private static let rateRange = Double(PlaybackState.supportedRateRange.lowerBound)
        ... Double(PlaybackState.supportedRateRange.upperBound)

    var body: some View {
        Section {
            HStack {
                Text(StudioFormat.percent(player.playbackRate))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Spacer()
                Button("Original Speed") { player.setPlaybackRate(1) }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            Slider(
                value: Binding(
                    get: { Double(player.playbackRate) },
                    set: { player.setPlaybackRate(Float(($0 * 20).rounded() / 20)) }
                ),
                in: Self.rateRange
            )
            .accessibilityLabel("Playback speed")
            .accessibilityValue(StudioFormat.percent(player.playbackRate))
        } footer: {
            Text("Slows the song without changing its key. 100% is the original tempo and the fastest Atarang plays.")
        }
    }
}

struct KeyToolContent: View {
    let player: StemPlayer

    var body: some View {
        Section {
            HStack {
                Text(StudioFormat.semitones(player.pitchSemitones))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Slider(
                value: Binding(
                    get: { player.pitchSemitones },
                    set: { player.setPitchSemitones($0.rounded()) }
                ),
                in: PlaybackState.supportedPitchRange,
                step: 1
            )
            .accessibilityLabel("Pitch transpose")
            .accessibilityValue(StudioFormat.semitones(player.pitchSemitones))
            HStack {
                Button("− Octave") { player.setPitchSemitones(-12) }
                Button("Reset") { player.setPitchSemitones(0) }
                Button("+ Octave") { player.setPitchSemitones(12) }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44)
        } footer: {
            Text("Changes key without changing playback speed. The transformed backing is also what gets recorded.")
        }
    }
}

struct TargetToolContent: View {
    let player: StemPlayer

    var body: some View {
        Section("The part you are practising") {
            Picker(
                "Practice target",
                selection: Binding(
                    get: {
                        player.practiceSettings.target
                            ?? player.activeStems.first
                            ?? .vocals
                    },
                    set: { player.setPracticeTarget($0) }
                )
            ) {
                ForEach(player.activeStems) { stem in
                    Label(stem.title, systemImage: stem.icon).tag(stem)
                }
            }
            .pickerStyle(.menu)
        }
        Section {
            ForEach(TargetMixPreset.allCases) { preset in
                Button {
                    player.applyTargetPreset(preset)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title).font(.subheadline.weight(.semibold))
                            Text(preset.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if player.practiceSettings.preset == preset {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.indigo)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text("A preset sets every stem at once. Fine-tune any of them on the Mixer stage.")
        }
    }
}

struct ClickToolContent: View {
    let player: StemPlayer

    var body: some View {
        Section {
            Toggle(
                "Metronome",
                isOn: Binding(
                    get: { player.practiceSettings.metronomeEnabled },
                    set: { player.setMetronomeEnabled($0) }
                )
            )
            HStack {
                TextField(
                    "BPM",
                    value: Binding(
                        get: { player.practiceSettings.metronomeBPM },
                        set: { player.setMetronomeBPM($0) }
                    ),
                    format: .number
                )
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 90)
                Text("BPM").foregroundStyle(.secondary)
                Spacer()
                Button("Tap Tempo") { player.tapTempo() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
            }
            Picker(
                "Subdivision",
                selection: Binding(
                    get: { player.practiceSettings.metronomeSubdivision },
                    set: { player.setMetronomeSubdivision($0) }
                )
            ) {
                ForEach(MetronomeSubdivision.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Toggle(
                "Accent every four beats",
                isOn: Binding(
                    get: { player.practiceSettings.metronomeAccentEnabled },
                    set: { player.setMetronomeAccentEnabled($0) }
                )
            )
            HStack {
                Image(systemName: "speaker.wave.1")
                Slider(
                    value: Binding(
                        get: { player.practiceSettings.metronomeLevel },
                        set: { player.setMetronomeLevel($0) }
                    ),
                    in: 0...1
                )
                .accessibilityLabel("Metronome click level")
            }
            Toggle(
                "Metronome only",
                isOn: Binding(
                    get: { player.practiceSettings.metronomeOnly },
                    set: { player.setMetronomeOnly($0) }
                )
            )
        }
        Section {
            Button("Align First Downbeat Here") { player.alignMetronome() }
                .frame(minHeight: 44)
        } footer: {
            Text("Aligned at \(StudioFormat.time(player.practiceSettings.metronomeAlignment)). Atarang does not detect the song's tempo yet, so the click is aligned by hand.")
        }
    }
}

struct RepetitionToolContent: View {
    let player: StemPlayer

    var body: some View {
        if player.practiceSettings.loopRange == nil {
            Section {
                Label("Set an A–B loop first", systemImage: "repeat")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Repetitions and the tempo ramp both count loop passes, so they need a loop to count.")
            }
        } else {
            Section {
                Stepper(
                    player.practiceSettings.repetitionTarget == 0
                        ? "Repeat until stopped"
                        : "\(player.practiceSettings.repetitionTarget) repetitions",
                    value: Binding(
                        get: { player.practiceSettings.repetitionTarget },
                        set: { player.setRepetitionTarget($0) }
                    ),
                    in: 0...99
                )
                Stepper(
                    player.practiceSettings.repetitionPause == 0
                        ? "No pause between repetitions"
                        : "\(player.practiceSettings.repetitionPause.formatted()) second pause",
                    value: Binding(
                        get: { player.practiceSettings.repetitionPause },
                        set: { player.setRepetitionPause($0) }
                    ),
                    in: 0...10,
                    step: 1
                )
                if player.practiceSettings.repetitionTarget > 0 {
                    LabeledContent(
                        "Progress",
                        value: "\(player.completedRepetitions) done · \(player.remainingRepetitions) left"
                    )
                    .monospacedDigit()
                }
            }
            Section("Tempo ramp") {
                Toggle(
                    "Ramp tempo",
                    isOn: Binding(
                        get: { player.practiceSettings.tempoRampEnabled },
                        set: { player.configureTempoRamp(enabled: $0) }
                    )
                )
                if player.practiceSettings.tempoRampEnabled {
                    rateMenu(
                        "Start",
                        value: player.practiceSettings.tempoRampStart,
                        set: { player.configureTempoRamp(start: $0) }
                    )
                    rateMenu(
                        "Add each time",
                        value: player.practiceSettings.tempoRampIncrement,
                        isIncrement: true,
                        set: { player.configureTempoRamp(increment: $0) }
                    )
                    rateMenu(
                        "Target",
                        value: player.practiceSettings.tempoRampTarget,
                        set: { player.configureTempoRamp(target: $0) }
                    )
                    Stepper(
                        "Increase every \(player.practiceSettings.tempoRampEvery) repetition\(player.practiceSettings.tempoRampEvery == 1 ? "" : "s")",
                        value: Binding(
                            get: { player.practiceSettings.tempoRampEvery },
                            set: { player.configureTempoRamp(every: $0) }
                        ),
                        in: 1...10
                    )
                    HStack {
                        Button("Start Ramp") { player.beginTempoRamp() }
                            .buttonStyle(.borderedProminent)
                        Button(player.isTempoRampHeld ? "Resume Ramp" : "Hold Speed") {
                            player.toggleTempoRampHold()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(minHeight: 44)
                }
            }
            Section {
                Button("Stop Structured Practice", role: .destructive) {
                    player.stopStructuredPractice()
                }
                .frame(minHeight: 44)
                .disabled(!player.isPlaying && player.completedRepetitions == 0)
            }
        }
    }

    private func rateMenu(
        _ title: String,
        value: Float,
        isIncrement: Bool = false,
        set: @escaping (Float) -> Void
    ) -> some View {
        let values: [Float] = isIncrement
            ? [0.01, 0.02, 0.05, 0.1]
            : [0.5, 0.6, 0.75, 0.8, 0.9, 1]
        return Picker(
            title,
            selection: Binding(get: { value }, set: { set($0) })
        ) {
            ForEach(values, id: \.self) { rate in
                Text("\(isIncrement ? "+" : "")\(StudioFormat.percent(rate))").tag(rate)
            }
        }
        .pickerStyle(.menu)
    }
}

struct SectionsToolContent: View {
    let player: StemPlayer
    @State private var editingSectionID: UUID?
    @State private var nameDraft = ""

    var body: some View {
        Section {
            Button("Save Current A–B Range") {
                player.saveCurrentSection()
                Haptics.boundarySet()
            }
            .frame(minHeight: 44)
            .disabled(player.practiceSettings.loopRange == nil)
        } footer: {
            Text("A saved section stores its A–B range only. Speed, key, and mix stay as you left them, so loading a section never changes what you hear.")
        }
        Section {
            if player.practiceSettings.savedSections.isEmpty {
                Text("No saved sections yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(player.practiceSettings.savedSections) { section in
                    HStack {
                        Button {
                            player.loadSection(section.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.name).font(.subheadline.weight(.semibold))
                                Text("\(StudioFormat.time(section.start)) – \(StudioFormat.time(section.end))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Rename") {
                                nameDraft = section.name
                                editingSectionID = section.id
                            }
                            Button("Delete", role: .destructive) {
                                player.deleteSection(section.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Options for \(section.name)")
                    }
                }
            }
        }
        .alert(
            "Rename Section",
            isPresented: Binding(
                get: { editingSectionID != nil },
                set: { if !$0 { editingSectionID = nil } }
            )
        ) {
            TextField("Section name", text: $nameDraft)
            Button("Save") {
                if let editingSectionID {
                    player.renameSection(editingSectionID, to: nameDraft)
                }
                editingSectionID = nil
            }
            Button("Cancel", role: .cancel) { editingSectionID = nil }
        }
    }
}

struct CountInToolContent: View {
    let player: StemPlayer

    var body: some View {
        Section {
            Picker(
                "Count-in",
                selection: Binding(
                    get: { player.practiceSettings.countInClicks },
                    set: { player.setCountInClicks($0) }
                )
            ) {
                Text("Off").tag(0)
                Text("2 clicks").tag(2)
                Text("4 clicks").tag(4)
            }
            .pickerStyle(.segmented)
            .disabled(player.isCountingIn)
        } footer: {
            Text("One click per second before playback or recording, with a tap you can feel. The count-in is never recorded.")
        }
    }
}
