import SwiftUI

/// Everything about a take, in the one place the user is already looking.
///
/// Before this, recording state was scattered: a status line and a meter in the
/// Mix card, level sliders in a third box, take comparison buttons at the bottom
/// of the Practice stack, and a dozen controls that silently went grey. Now
/// recording is a *mode* — the transport says so once, explains what is locked,
/// and carries the meter and the levels the take was captured with.
struct RecordingModeStrip: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let player: StemPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if player.isRecording {
                MicrophoneMeter(level: player.microphoneMeterLevel)
                    .accessibilityLabel("Live microphone input")
                    .accessibilityValue(microphoneLevelDescription)
                levels
                Text(explanation)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(
                player.isCountingIn
                    ? "Count-in \(player.countInRemaining)"
                    : "Recording \(StudioFormat.time(player.recordingDuration))"
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.red)
            Spacer()
            if player.isEchoCancellationActive {
                Label("Bleed reduction", systemImage: "waveform.and.mic")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Read-only on purpose. These two numbers are metadata captured when the
    /// take starts; the audio is written raw and balanced later, so the place to
    /// change the balance is the Library's mix editor, not a slider that would
    /// pretend to be doing something during the take.
    private var levels: some View {
        HStack(spacing: 14) {
            Label(
                "Mic \(StudioFormat.percent(player.recordingMicrophoneLevel))",
                systemImage: "mic.fill"
            )
            Label(
                "Backing \(StudioFormat.percent(player.recordingBackingLevel))",
                systemImage: "waveform"
            )
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var explanation: String {
        let base = player.isLoopTakeRecording
            ? "Recording one pass from A to B. It stops at B on its own."
            : "Recording. Loop, speed, key, mix, and practice tools are locked until you stop."
        return base + " Balance the mic and backing afterwards in the Library."
    }

    private var microphoneLevelDescription: String {
        switch player.microphoneMeterLevel {
        case ..<0.2: "Very low"
        case ..<0.55: "Good"
        case ..<0.85: "Strong"
        default: "Very loud"
        }
    }
}

/// Reference versus Latest Take, in the transport rather than at the bottom of
/// a practice stack. It appears only once there is something to compare.
struct TakeComparisonStrip: View {
    let player: StemPlayer
    let isPreviewPlaying: Bool
    let playReference: () -> Void
    let toggleTake: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Compare", systemImage: "arrow.left.arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Reference", action: playReference)
                .buttonStyle(.bordered)
            Button(isPreviewPlaying ? "Stop Take" : "Latest Take", action: toggleTake)
                .buttonStyle(.borderedProminent)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }
}

struct MicrophoneMeter: View {
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
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
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

/// Shown once, before the first take.
struct RecordingIntroductionSheet: View {
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
