import XCTest
@testable import Atarang

final class AnalysisQueueTests: XCTestCase {
    func testTwoJobsNeverRunAtTheSameTime() async throws {
        let queue = AnalysisQueue()
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await queue.submit(kind: .separation, title: "job") { _ in
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(20))
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peakConcurrency
        let completed = await tracker.completed
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(completed, 5)
    }

    /// The bug this guards against: job A's cleanup, or its last progress
    /// report, landing after job B has started and overwriting B's state.
    func testACancelledJobCannotAlterTheJobThatReplacesIt() async throws {
        let queue = AnalysisQueue()
        let center = await AnalysisProgressCenter.shared
        let started = Latch()

        let first = Task {
            try await queue.submit(kind: .separation, title: "A") { context in
                await context.report("A is working", progress: 0.5)
                await started.open()
                // Keeps reporting after the cancel lands, which is exactly the
                // late-report case the token guard exists for.
                for _ in 0..<50 {
                    try await Task.sleep(for: .milliseconds(10))
                    await context.report("A is still here", progress: 0.9)
                }
            }
        }
        await started.wait()
        first.cancel()
        let firstOutcome = try await first.value
        XCTAssertTrue(firstOutcome.wasCancelled, "Cancellation is not a failure")

        let secondOutcome = try await queue.submit(kind: .separation, title: "B") { context in
            await context.report("B is working", progress: 0.25)
            // Give anything A still had to say time to arrive while B is current.
            try await Task.sleep(for: .milliseconds(150))
            return await (center.active?.status, center.active?.progress)
        }

        let reported = try XCTUnwrap(secondOutcome.value)
        XCTAssertEqual(reported.0, "B is working")
        XCTAssertEqual(try XCTUnwrap(reported.1), 0.25, accuracy: 0.0001)
        // B's own entry goes away when B ends, without A having to say so.
        let leftover = await center.active
        XCTAssertNil(leftover)
    }

    func testNoJobRunsDuringATake() async throws {
        let queue = AnalysisQueue()
        await queue.setRecording(true)
        let sawGateClosed = Mutable(false)
        let finished = Latch()

        let job = Task {
            try await queue.submit(kind: .chordAnalysis, title: "chords") { _ in
                await sawGateClosed.set(await queue.isRecording)
                await finished.open()
            }
        }

        // Long enough that a queue without the gate would have finished.
        try await Task.sleep(for: .milliseconds(200))
        let startedDuringTake = await sawGateClosed.value
        XCTAssertFalse(startedDuringTake, "The job started during a take")
        let waiting = await AnalysisProgressCenter.shared.jobs.contains {
            $0.state == .waitingForRecording
        }
        XCTAssertTrue(waiting)

        await queue.setRecording(false)
        await finished.wait()
        _ = try await job.value
        let ranWhileRecording = await sawGateClosed.value
        XCTAssertFalse(ranWhileRecording)
    }

    func testAJobWaitingOnATakeCanStillBeCancelled() async throws {
        let queue = AnalysisQueue()
        await queue.setRecording(true)
        let didRun = Mutable(false)

        let job = Task {
            try await queue.submit(kind: .transcription, title: "lyrics") { _ in
                await didRun.set(true)
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        job.cancel()
        let outcome = try await job.value

        XCTAssertTrue(outcome.wasCancelled)
        let ranBeforeCancel = await didRun.value
        XCTAssertFalse(ranBeforeCancel)
        // Reopening the gate must not resurrect it.
        await queue.setRecording(false)
        try await Task.sleep(for: .milliseconds(100))
        let ranAfterGateOpened = await didRun.value
        XCTAssertFalse(ranAfterGateOpened)
    }

    func testAFailureThrowsAndTheQueueKeepsGoing() async throws {
        let queue = AnalysisQueue()

        do {
            _ = try await queue.submit(kind: .separation, title: "doomed") { _ in
                throw QueueTestError.expected
            }
            XCTFail("A genuine failure must reach the caller")
        } catch {
            XCTAssertTrue(error is QueueTestError)
        }

        let outcome = try await queue.submit(kind: .separation, title: "next") { _ in 7 }
        XCTAssertEqual(outcome.value, 7)
        let leftover = await AnalysisProgressCenter.shared.active
        XCTAssertNil(leftover)
    }

    @MainActor
    func testTheProgressSurfaceDropsReportsFromAJobItNoLongerTracks() {
        let center = AnalysisProgressCenter.shared
        let stale = AnalysisJobToken(id: UUID(), generation: 1)
        let current = AnalysisJobToken(id: UUID(), generation: 2)
        center.add(token: current, kind: .separation, title: "current")

        center.report(stale, status: "stale", progress: 0.99, estimateFraction: nil)

        XCTAssertEqual(center.jobs.count, 1)
        XCTAssertEqual(center.active?.token, current)
        XCTAssertNotEqual(center.active?.status, "stale")
        center.remove(current)
        XCTAssertNil(center.active)
    }

    /// Resubmitting the same work produces a new generation, which is what makes
    /// the superseded run recognisable even though it kept the same ID.
    @MainActor
    func testASupersededGenerationCannotReportOverItsReplacement() {
        let center = AnalysisProgressCenter.shared
        let first = AnalysisJobToken(id: UUID(), generation: 1)
        let second = AnalysisJobToken(id: first.id, generation: 2)
        center.add(token: second, kind: .separation, title: "retry")

        center.report(first, status: "superseded", progress: 1, estimateFraction: nil)

        XCTAssertEqual(center.active?.token.generation, 2)
        XCTAssertNotEqual(center.active?.status, "superseded")
        center.remove(second)
    }
}

private enum QueueTestError: Error { case expected }

/// A one-shot signal, so the tests can wait for a job to reach a point without
/// passing a non-`Sendable` `XCTestExpectation` into a `@Sendable` closure.
private actor Latch {
    private var isOpen = false

    func open() { isOpen = true }

    func wait(timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !isOpen, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor Mutable<Value: Sendable> {
    private(set) var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ newValue: Value) { value = newValue }
}

private actor OverlapTracker {
    private var active = 0
    private(set) var peakConcurrency = 0
    private(set) var completed = 0

    func enter() {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }
}
