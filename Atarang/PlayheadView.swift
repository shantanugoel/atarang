import SwiftUI

/// Redraws its content at display rate from the player's render clock.
///
/// The position timer only fires at 10 Hz, which is enough for bookkeeping but
/// visibly steppy for a playhead. `TimelineView(.animation)` drives this at the
/// display's refresh rate and asks the player for a freshly computed,
/// latency-compensated position each frame, without the player publishing
/// anything.
///
/// Keep the content small. Everything inside redraws every frame while the
/// song plays, so it should be a readout or a marker — never a section of the
/// screen.
struct PlayheadView<Content: View>: View {
    let player: StemPlayer
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View {
        TimelineView(.animation(paused: !player.isPlaying)) { _ in
            content(player.currentPosition())
        }
    }
}
