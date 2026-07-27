import SwiftUI
import UIKit

/// The words, at arm's length, with nothing else on screen.
///
/// This is the first full-screen practice mode in the app, and it is what the
/// Phase 1 idle-timer work was scoped in anticipation of: someone standing with
/// a guitar, three metres from the phone, not touching it for four minutes.
/// Everything that is not the current line is either shrunk or gone.
struct SingAlongView: View {
    @Environment(\.dismiss) private var dismiss
    let player: StemPlayer
    let store: LyricsStore
    let requestRecording: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            LyricsStage(player: player, store: store, isSingAlong: true)
            transport
        }
        .background(Color(.systemBackground))
        // The screen must not sleep here for the same reason it must not during
        // playback, only more so: this mode exists precisely for the stretches
        // when nobody is touching the phone.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(player.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if player.isRecording {
                // Small, and only while it matters: the singer needs to know
                // the microphone is hearing them, not to watch a meter.
                MicrophoneMeter(level: player.microphoneMeterLevel)
                    .frame(width: 120)
                    .accessibilityLabel("Live microphone input")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Leave sing-along mode")
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    /// Four controls. Everything else stays in Studio, one dismissal away.
    private var transport: some View {
        HStack(spacing: 14) {
            PlayheadView(player: player) { position in
                Text(StudioFormat.time(position))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .leading)
            }
            Spacer(minLength: 0)
            control("gobackward.5", label: "Back 5", isEnabled: !player.isRecording) {
                player.skipBackward()
            }
            control(
                player.isPlaying || player.isCountingIn ? "pause.fill" : "play.fill",
                label: player.isPlaying ? "Pause" : "Play",
                tint: .indigo,
                isProminent: true,
                isEnabled: !player.isRecording
            ) {
                player.togglePlayback()
            }
            control(
                player.practiceSettings.isLoopEnabled ? "repeat.circle.fill" : "repeat",
                label: "Loop",
                tint: .green,
                isProminent: player.practiceSettings.isLoopEnabled,
                isEnabled: !player.isRecording && player.practiceSettings.loopRange != nil
            ) {
                player.setLoopEnabled(!player.practiceSettings.isLoopEnabled)
            }
            control(
                player.isRecording ? "stop.fill" : "record.circle",
                label: player.isRecording ? "Stop" : "Record",
                tint: .red,
                isProminent: player.isRecording,
                isEnabled: !player.isCountingIn,
                action: requestRecording
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func control(
        _ systemImage: String,
        label: String,
        tint: Color = .primary,
        isProminent: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .padding(.horizontal, 10)
                .frame(minWidth: 52, minHeight: 44)
                .background(
                    isProminent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)),
                    in: Capsule()
                )
                .foregroundStyle(isProminent ? Color.white : tint)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}
