import Foundation

/// Runs long blocking work off the caller's actor **without** losing
/// cancellation.
///
/// `Task.detached` deliberately inherits nothing from its context — including
/// the cancellation state. The separators used it to get inference off the main
/// actor, and each one dutifully called `Task.checkCancellation()` at the top of
/// its chunk loop, but that check ran inside the detached task, which nobody had
/// cancelled. The visible symptom was a Cancel button that did nothing: the
/// separation ran to completion in the background and only its result was
/// discarded.
///
/// Forwarding the cancel to the detached handle is what makes those existing
/// `checkCancellation()` calls mean something.
/// `work` is `sending` rather than `@Sendable` so it can carry the same
/// exclusively-owned values `Task.detached` accepts directly — the separators
/// hand over a freshly decoded `AVAudioPCMBuffer` nobody else holds.
func runCancellable<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: sending @escaping () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority, operation: work)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
