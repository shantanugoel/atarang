import SwiftUI

/// The one part of Studio that never scrolls and never goes away while a song
/// is loaded.
///
/// Row 1 is the timeline: waveform overview, shaded loop, A and B handles,
/// saved-section ticks, playhead. Row 2 is the controls the user reaches for
/// with an instrument in their hands.
///
/// This replaces both in-scroll position sliders. There is exactly one place to
/// seek now, and it is always on screen.
struct TransportBar: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let player: StemPlayer
    let waveform: WaveformSummary?
    let requestRecording: () -> Void
    /// Rendered inside the bar in landscape, where a separate chip band would
    /// cost a third of the height. `nil` in every other layout.
    var foldedChips: AnyView?

    @State private var loopArmed = false

    var body: some View {
        VStack(spacing: 10) {
            if player.isRecording || player.isCountingIn {
                RecordingModeStrip(player: player)
            }
            TransportTimeline(player: player, waveform: waveform)
            if let foldedChips {
                // Landscape: the chips share the control row rather than
                // claiming one of their own, which is the difference between
                // the Stage having room and not.
                HStack(spacing: spacing) {
                    primaryButtons
                    foldedChips
                    SpeedMenu(player: player)
                    KeyMenu(player: player)
                }
            } else {
                controls
            }
        }
        .onChange(of: player.isLoaded) { _, _ in loopArmed = false }
        .onChange(of: player.title) { _, _ in loopArmed = false }
    }

    // MARK: - Row 2

    /// One row when the six controls fit, two when they do not — at an
    /// accessibility text size on a small phone they do not, and a truncated
    /// "10 0%" speed readout is worse than a second line.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                primaryButtons
                Spacer(minLength: 0)
                SpeedMenu(player: player)
                KeyMenu(player: player)
            }
            VStack(spacing: 8) {
                HStack(spacing: spacing) {
                    primaryButtons
                    Spacer(minLength: 0)
                }
                HStack(spacing: spacing) {
                    Spacer(minLength: 0)
                    SpeedMenu(player: player)
                    KeyMenu(player: player)
                }
            }
        }
    }

    private var spacing: CGFloat { dynamicTypeSize.isAccessibilitySize ? 8 : 10 }

    @ViewBuilder
    private var primaryButtons: some View {
        Group {
            transportButton(
                "Back 5",
                systemImage: "gobackward.5",
                isEnabled: !player.isRecording
            ) {
                player.skipBackward()
            }

            transportButton(
                playPauseTitle,
                systemImage: player.isPlaying || player.isCountingIn
                    ? "pause.fill"
                    : "play.fill",
                tint: .indigo,
                isProminent: true,
                isEnabled: !player.isRecording
            ) {
                player.togglePlayback()
            }

            transportButton(
                player.isRecording ? "Stop" : "Record",
                systemImage: player.isRecording ? "stop.fill" : "record.circle",
                tint: .red,
                isProminent: player.isRecording,
                isEnabled: !player.isCountingIn,
                action: requestRecording
            )

            loopButton
        }
    }

    private var playPauseTitle: String {
        if player.isCountingIn { return "Cancel" }
        return player.isPlaying ? "Pause" : "Play"
    }

    /// The A–B button, in the shape practice hardware has used for decades:
    /// tap once to drop A, again to drop B and start looping, again to switch
    /// the loop off. It is the reason setting a loop needs no sheet at all.
    private var loopButton: some View {
        transportButton(
            loopTitle,
            systemImage: loopArmed ? "a.circle.fill" : "repeat",
            tint: .green,
            isProminent: loopArmed || player.practiceSettings.isLoopEnabled,
            isEnabled: !player.isRecording
        ) {
            if loopArmed {
                player.setLoopBoundaryB()
                player.setLoopEnabled(true)
                loopArmed = false
            } else if player.practiceSettings.loopRange != nil {
                player.setLoopEnabled(!player.practiceSettings.isLoopEnabled)
            } else {
                player.setLoopBoundaryA()
                loopArmed = true
            }
            Haptics.boundarySet()
        }
        .contextMenu {
            Button("Set A Here") {
                player.setLoopBoundaryA()
                loopArmed = true
                Haptics.boundarySet()
            }
            Button("Set B Here") {
                player.setLoopBoundaryB()
                loopArmed = false
                Haptics.boundarySet()
            }
            if player.practiceSettings.loopRange != nil {
                Button("Clear Loop", role: .destructive) {
                    player.clearLoop()
                    loopArmed = false
                }
            }
        }
        .accessibilityHint(loopAccessibilityHint)
    }

    private var loopTitle: String {
        if loopArmed { return "Set B" }
        if player.practiceSettings.loopRange == nil { return "Set A" }
        return player.practiceSettings.isLoopEnabled ? "Loop On" : "Loop Off"
    }

    private var loopAccessibilityHint: String {
        if loopArmed { return "Sets the loop end at the playhead and starts looping" }
        if player.practiceSettings.loopRange == nil {
            return "Sets the loop start at the playhead"
        }
        return "Turns the A–B loop on or off"
    }

    private func transportButton(
        _ title: String,
        systemImage: String,
        tint: Color = .primary,
        isProminent: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.headline)
                    // The capsule grows with the glyph rather than clipping it:
                    // at accessibility sizes a fixed 46×34 squashed the play
                    // triangle into an unreadable wedge.
                    .padding(.horizontal, 8)
                    .frame(minWidth: 46, minHeight: 34)
                    .background(
                        isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)),
                        in: Capsule()
                    )
                    .foregroundStyle(isProminent ? Color.white : tint)
                // Captions are the first thing to go when height is scarce:
                // landscape has roughly half of it, and these four icons are
                // the most conventional in the app.
                if !dynamicTypeSize.isAccessibilitySize, verticalSizeClass != .compact {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 46, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}

// MARK: - Speed and key

/// Speed lives in the transport as a menu rather than a sheet: slowing a
/// passage down is the single most common practice action, and it should cost
/// two taps and no modal.
struct SpeedMenu: View {
    let player: StemPlayer

    var body: some View {
        Menu {
            ForEach([1.0, 0.9, 0.75, 0.6, 0.5], id: \.self) { rate in
                Button {
                    player.setPlaybackRate(Float(rate))
                } label: {
                    Label(
                        StudioFormat.percent(Float(rate)),
                        systemImage: abs(player.playbackRate - Float(rate)) < 0.001
                            ? "checkmark"
                            : "speedometer"
                    )
                }
            }
        } label: {
            TransportValueChip(
                systemImage: "speedometer",
                value: StudioFormat.percent(player.playbackRate)
            )
        }
        .disabled(player.isRecording)
        .accessibilityLabel("Playback speed")
        .accessibilityValue(StudioFormat.percent(player.playbackRate))
    }
}

struct KeyMenu: View {
    let player: StemPlayer

    var body: some View {
        Menu {
            Button("Original Key") { player.setPitchSemitones(0) }
            Divider()
            ForEach([1, 2, 3, -1, -2, -3], id: \.self) { step in
                Button(step > 0 ? "+\(step)" : "\(step)") {
                    player.setPitchSemitones(player.pitchSemitones + Float(step))
                }
            }
        } label: {
            TransportValueChip(
                systemImage: "music.note",
                value: StudioFormat.semitonesCompact(player.pitchSemitones)
            )
        }
        .disabled(player.isRecording)
        .accessibilityLabel("Key")
        .accessibilityValue(StudioFormat.semitones(player.pitchSemitones))
    }
}

private struct TransportValueChip: View {
    let systemImage: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(minHeight: 44)
        .foregroundStyle(.primary)
        .background(Color.primary.opacity(0.07), in: Capsule())
    }
}

// MARK: - Timeline

/// The scrubbable song overview.
///
/// A drag that starts on the A or B handle moves that boundary; a drag anywhere
/// else moves the playhead. Both route through the player's scrubbing
/// lifecycle, so one gesture is one engine stop and one resume — the fix Phase 1
/// made for the sliders this view replaces.
struct TransportTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let player: StemPlayer
    let waveform: WaveformSummary?

    private enum DragTarget { case playhead, loopStart, loopEnd }

    @State private var dragTarget: DragTarget?

    private static let handleWidth: CGFloat = 12

    /// Shorter on a phone held sideways, where the whole screen is 400 points
    /// tall and the transport must not eat the Stage.
    private var trackHeight: CGFloat {
        verticalSizeClass == .compact ? 36 : 56
    }

    var body: some View {
        VStack(spacing: 4) {
            track
            readout
        }
    }

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                WaveformOverviewShape(peaks: waveform?.peaks ?? [])
                    .fill(Color.secondary.opacity(waveform == nil ? 0.12 : 0.35))
                    .frame(height: trackHeight)

                if let loop = player.practiceSettings.loopRange, player.duration > 0 {
                    let startX = x(for: loop.start, in: width)
                    let endX = x(for: loop.end, in: width)
                    Rectangle()
                        .fill(Color.green.opacity(player.practiceSettings.isLoopEnabled ? 0.22 : 0.1))
                        .frame(width: max(2, endX - startX), height: trackHeight)
                        .offset(x: startX)
                    boundaryHandle(color: .green, label: "A")
                        .offset(x: startX - Self.handleWidth / 2)
                    boundaryHandle(color: .orange, label: "B")
                        .offset(x: endX - Self.handleWidth / 2)
                }

                ForEach(player.practiceSettings.savedSections) { section in
                    Rectangle()
                        .fill(Color.indigo.opacity(0.7))
                        .frame(width: 2, height: 8)
                        .offset(x: x(for: section.start, in: width), y: trackHeight / 2 - 4)
                        .accessibilityHidden(true)
                }

                PlayheadView(player: player) { position in
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 2.5, height: trackHeight)
                        .offset(x: x(for: position, in: width) - 1.25)
                        .shadow(radius: reduceMotion ? 0 : 1)
                }
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width))
        }
        .frame(height: trackHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to move the playhead five seconds")
        .accessibilityAdjustableAction { direction in
            let delta: TimeInterval = direction == .increment ? 5 : -5
            player.seek(to: min(player.duration, max(0, player.position + delta)))
        }
    }

    private var readout: some View {
        PlayheadView(player: player) { position in
            HStack(spacing: 6) {
                Text(StudioFormat.time(position))
                if let loop = player.practiceSettings.loopRange {
                    Spacer()
                    Text("A \(StudioFormat.time(loop.start))")
                        .foregroundStyle(.green)
                    Text("B \(StudioFormat.time(loop.end))")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("−\(StudioFormat.time(max(0, player.duration - position)))")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        // One line at every text size: the timeline above it is the thing that
        // must not move, and the same values are spoken by the track's
        // accessibility value anyway.
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        var value = "\(StudioFormat.time(player.position)) of \(StudioFormat.time(player.duration))"
        if let loop = player.practiceSettings.loopRange {
            value += ", loop \(StudioFormat.time(loop.start)) to \(StudioFormat.time(loop.end))"
            value += player.practiceSettings.isLoopEnabled ? ", on" : ", off"
        }
        return value
    }

    private func boundaryHandle(color: Color, label: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.handleWidth, height: 12)
                .background(color)
            Rectangle()
                .fill(color)
                .frame(width: 2)
        }
        .frame(width: Self.handleWidth, height: trackHeight, alignment: .top)
        .accessibilityHidden(true)
    }

    private func x(for time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard player.duration > 0, width > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / player.duration))) * width
    }

    private func time(atX x: CGFloat, in width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return min(player.duration, max(0, Double(x / width) * player.duration))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !player.isRecording, player.duration > 0 else { return }
                let target = dragTarget ?? resolveTarget(at: value.startLocation.x, in: width)
                if dragTarget == nil {
                    dragTarget = target
                    player.beginScrubbing()
                    if target != .playhead { Haptics.boundarySet() }
                }
                let moment = time(atX: value.location.x, in: width)
                switch target {
                case .playhead:
                    player.updateScrubPosition(moment)
                case .loopStart:
                    player.setLoopBoundaryA(at: moment)
                case .loopEnd:
                    player.setLoopBoundaryB(at: moment)
                }
            }
            .onEnded { _ in
                guard dragTarget != nil else { return }
                if dragTarget != .playhead { Haptics.boundarySet() }
                dragTarget = nil
                player.endScrubbing()
            }
    }

    /// A touch within a thumb's width of a handle grabs it. The playhead itself
    /// is not grabbable — a tap anywhere on the track already moves it.
    private func resolveTarget(at x: CGFloat, in width: CGFloat) -> DragTarget {
        guard let loop = player.practiceSettings.loopRange else { return .playhead }
        let grabRadius: CGFloat = 22
        if abs(x - self.x(for: loop.start, in: width)) <= grabRadius { return .loopStart }
        if abs(x - self.x(for: loop.end, in: width)) <= grabRadius { return .loopEnd }
        return .playhead
    }
}

/// The static overview, drawn as one path so a four-hundred-bucket waveform is
/// a single draw rather than four hundred views.
struct WaveformOverviewShape: Shape {
    let peaks: [Float]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !peaks.isEmpty else {
            // Before the measurement lands, a hairline keeps the track's
            // geometry stable so nothing jumps when it arrives.
            path.addRect(
                CGRect(x: 0, y: rect.midY - 1, width: rect.width, height: 2)
            )
            return path
        }
        let barWidth = rect.width / CGFloat(peaks.count)
        for (index, peak) in peaks.enumerated() {
            let height = max(1.5, CGFloat(peak) * rect.height)
            path.addRect(
                CGRect(
                    x: CGFloat(index) * barWidth,
                    y: rect.midY - height / 2,
                    width: max(0.6, barWidth - 0.4),
                    height: height
                )
            )
        }
        return path
    }
}
