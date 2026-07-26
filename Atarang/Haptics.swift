import UIKit

/// The small physical confirmations the redesign leans on.
///
/// Every one of these fires at a moment the user is *not* looking at the
/// screen — an A or B boundary set by ear, a loop coming round again, the last
/// repetition landing — which is the whole reason they are worth having in a
/// tool used while holding an instrument.
///
/// Generators are created per call rather than kept warm. `prepare()` exists to
/// shave the first-tap latency, but holding a generator alive keeps the Taptic
/// Engine spun up, and none of these fire often enough to justify that.
@MainActor
enum Haptics {
    /// A loop boundary was set, or a discrete control committed a value.
    static func boundarySet() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// The loop came round to A again.
    static func loopWrapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// One count-in click.
    static func countInTick() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// The repetition target was reached.
    static func targetReached() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
