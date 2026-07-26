import Foundation
import OSLog

/// The long-running work the app owns.
///
/// Every one of these is minutes long, competes for the same CPU, memory, and
/// disk, and writes into the library when it finishes. Two at once would make
/// each slower and both harder to reason about, so they share one queue.
enum AnalysisJobKind: String, Sendable, CaseIterable {
    case separation
    case transcription
    case chordAnalysis

    /// Shown while the job is waiting rather than working.
    var waitingDescription: String {
        switch self {
        case .separation: "Separation is waiting"
        case .transcription: "Transcription is waiting"
        case .chordAnalysis: "Chord analysis is waiting"
        }
    }

    fileprivate var signpostName: StaticString {
        switch self {
        case .separation: "Separation"
        case .transcription: "Transcription"
        case .chordAnalysis: "ChordAnalysis"
        }
    }
}

/// Identifies one submitted job for its whole life.
///
/// The generation is what makes a *late* report recognisable. Resubmitting the
/// same work produces a new token, so anything the superseded run still has to
/// say no longer matches anything the queue is tracking, and is dropped instead
/// of overwriting its replacement.
struct AnalysisJobToken: Hashable, Sendable {
    let id: UUID
    let generation: Int
}

/// How a job ended.
///
/// Cancellation is a terminal state of its own rather than an error: the user
/// asked for the work to stop and it stopped, so there is nothing to report and
/// nothing to apologise for. Only genuine failures throw.
enum AnalysisOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case cancelled

    var value: Value? {
        switch self {
        case .finished(let value): value
        case .cancelled: nil
        }
    }

    var wasCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// The only channel a running job has for describing itself.
///
/// Every update carries the job's token, so a report can always be matched
/// against the job the queue believes is current — and discarded when it is not.
struct AnalysisJobContext: Sendable {
    let token: AnalysisJobToken
    let kind: AnalysisJobKind

    /// Reports one step of the job.
    ///
    /// `estimateFraction` is the fraction of the *slow phase* that is done,
    /// which is not the same number as `progress`: a separation spends its first
    /// fifth downloading and loading a model, and timing the inference against
    /// that would produce a wildly optimistic estimate. Pass `nil` while no
    /// meaningful estimate can be made.
    @MainActor
    func report(
        _ status: String,
        progress: Double,
        estimateFraction: Double? = nil
    ) {
        AnalysisProgressCenter.shared.report(
            token,
            status: status,
            progress: progress,
            estimateFraction: estimateFraction
        )
    }
}

/// The one place the UI looks to find out what long-running work is happening.
///
/// Jobs used to each publish their own `isWorking`/`progress`/`statusText`,
/// which is how a cancelled job could clear the state of the job that replaced
/// it. Here every job is a separate entry keyed by its token, and an update for
/// a token that is no longer present is simply dropped.
@MainActor
@Observable
final class AnalysisProgressCenter {
    static let shared = AnalysisProgressCenter()

    struct Job: Identifiable, Sendable {
        enum State: Sendable {
            case waitingForTurn
            case waitingForRecording
            case running
        }

        let token: AnalysisJobToken
        let kind: AnalysisJobKind
        let title: String
        var status: String
        var progress: Double
        var estimatedRemainingText: String?
        var state: State

        var id: UUID { token.id }

        var isWaiting: Bool { state != .running }
    }

    private(set) var jobs: [Job] = []

    /// The job worth showing: whichever one is actually working, or the next one
    /// in line when everything is still waiting.
    var active: Job? {
        jobs.first { $0.state == .running } ?? jobs.first
    }

    var isBusy: Bool { !jobs.isEmpty }

    @ObservationIgnored private var estimateAnchors: [UUID: Date] = [:]

    func add(token: AnalysisJobToken, kind: AnalysisJobKind, title: String) {
        jobs.append(
            Job(
                token: token,
                kind: kind,
                title: title,
                status: kind.waitingDescription,
                progress: 0,
                estimatedRemainingText: nil,
                state: .waitingForTurn
            )
        )
    }

    func setState(_ state: Job.State, for token: AnalysisJobToken) {
        guard let index = index(of: token) else { return }
        jobs[index].state = state
        if state == .waitingForRecording {
            jobs[index].status = "Waiting until this take finishes…"
        }
    }

    func report(
        _ token: AnalysisJobToken,
        status: String,
        progress: Double,
        estimateFraction: Double?
    ) {
        guard let index = index(of: token) else { return }
        jobs[index].status = status
        jobs[index].progress = min(1, max(0, progress))
        jobs[index].estimatedRemainingText = estimatedRemainingText(
            for: token,
            fraction: estimateFraction
        )
    }

    func remove(_ token: AnalysisJobToken) {
        estimateAnchors[token.id] = nil
        jobs.removeAll { $0.token == token }
    }

    /// Cancels the job the user can see. The queue owns the task handle; this
    /// only asks it to stop.
    func cancelActive() {
        guard let token = active?.token else { return }
        Task { await AnalysisQueue.shared.cancel(token.id) }
    }

    private func index(of token: AnalysisJobToken) -> Int? {
        jobs.firstIndex { $0.token == token }
    }

    private func estimatedRemainingText(
        for token: AnalysisJobToken,
        fraction: Double?
    ) -> String? {
        guard let fraction else {
            estimateAnchors[token.id] = nil
            return nil
        }
        let anchor = estimateAnchors[token.id] ?? Date()
        estimateAnchors[token.id] = anchor
        guard fraction > 0.02, fraction < 1 else { return nil }
        let elapsed = Date().timeIntervalSince(anchor)
        let remaining = elapsed * (1 - fraction) / fraction
        guard remaining.isFinite, remaining > 5 else { return "Almost done" }
        let minutes = max(1, Int(ceil(remaining / 60)))
        return minutes == 1
            ? "About 1 minute remaining"
            : "About \(minutes) minutes remaining"
    }
}

/// Runs the app's long work one job at a time, globally.
///
/// Serialization is the same chaining trick `SerialLane` uses — an actor alone
/// would not do it, because awaiting inside an actor method lets the next caller
/// in. What this adds on top is identity: each job has a token, a cancellation
/// handle the queue owns, and an entry in one shared progress surface, so
/// cancelling one job cannot disturb the next.
actor AnalysisQueue {
    static let shared = AnalysisQueue()

    private var tail: Task<Void, Never>?
    private var generationCounter = 0
    private var cancellations: [UUID: @Sendable () -> Void] = [:]
    /// Whether a take is currently holding every job back.
    private(set) var isRecording = false

    private let signposter = OSSignposter(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Analysis"
    )
    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Analysis"
    )

    /// Submits work and waits for it. Returns when the job has finished or been
    /// cancelled; only a genuine failure throws.
    ///
    /// Cancelling the *caller's* task cancels the job, which is what lets a
    /// screen going away stop the work it started.
    ///
    /// A job must not submit another one: the second would wait behind the first,
    /// which is waiting for it. Work that needs several stages belongs in one job.
    func submit<Value: Sendable>(
        kind: AnalysisJobKind,
        title: String,
        work: @escaping @Sendable (AnalysisJobContext) async throws -> Value
    ) async throws -> AnalysisOutcome<Value> {
        generationCounter += 1
        let token = AnalysisJobToken(id: UUID(), generation: generationCounter)
        let context = AnalysisJobContext(token: token, kind: kind)
        await AnalysisProgressCenter.shared.add(
            token: token,
            kind: kind,
            title: title
        )

        let previous = tail
        let signposter = signposter
        // `.utility` because none of this is what the user is waiting on right
        // now: playback, recording, and the interface must all stay ahead of it.
        let job = Task<AnalysisOutcome<Value>, Error>(priority: .utility) {
            await previous?.value
            do {
                try await self.waitUntilRunnable(token)
                let signpostID = signposter.makeSignpostID()
                let interval = signposter.beginInterval(kind.signpostName, id: signpostID)
                defer { signposter.endInterval(kind.signpostName, interval) }
                return .finished(try await work(context))
            } catch is CancellationError {
                return .cancelled
            } catch let error as URLError where error.code == .cancelled {
                // A cancelled transfer is the same terminal state; URLSession
                // just reports it in its own currency.
                return .cancelled
            }
        }
        // Everything below runs before the job can re-enter this actor, so the
        // handle is always in place before the job could need cancelling.
        tail = Task { _ = try? await job.value }
        cancellations[token.id] = { job.cancel() }

        return try await withTaskCancellationHandler {
            do {
                let outcome = try await job.value
                await retire(token, cancelled: outcome.wasCancelled)
                return outcome
            } catch {
                await retire(token, cancelled: false)
                throw error
            }
        } onCancel: {
            Task { await self.cancel(token.id) }
        }
    }

    /// Asks a job to stop. Unknown IDs — a job that has already ended — do
    /// nothing, rather than reaching into whatever is running now.
    func cancel(_ id: UUID) {
        cancellations[id]?()
    }

    /// Recording owns the audio hardware and the user's attention, and a take
    /// that glitches cannot be re-recorded from a saved buffer. Nothing else
    /// starts until it is over.
    func setRecording(_ recording: Bool) {
        isRecording = recording
    }

    private func waitUntilRunnable(_ token: AnalysisJobToken) async throws {
        try Task.checkCancellation()
        if isRecording {
            await AnalysisProgressCenter.shared.setState(
                .waitingForRecording,
                for: token
            )
            // A take ends on a user action, minutes from now, and not on any
            // signal this queue could await. Re-reading a boolean five times a
            // second costs nothing beside the work it is holding back.
            while isRecording {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try Task.checkCancellation()
        await AnalysisProgressCenter.shared.setState(.running, for: token)
    }

    /// Cleanup is scoped to one token, so a job that ends late cannot clear the
    /// state or the handle of the job that replaced it.
    private func retire(_ token: AnalysisJobToken, cancelled: Bool) async {
        cancellations[token.id] = nil
        await AnalysisProgressCenter.shared.remove(token)
        if cancelled {
            logger.info("Analysis job cancelled (generation \(token.generation, privacy: .public))")
        }
    }
}
