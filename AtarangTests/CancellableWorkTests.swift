import XCTest
@testable import Atarang

final class CancellableWorkTests: XCTestCase {
    /// The defect this exists for: `Task.detached` inherits no cancellation, so
    /// a `checkCancellation()` inside the detached work never fires and the
    /// Cancel button does nothing.
    func testCancellingTheCallerStopsTheDetachedWork() async throws {
        let started = expectation(description: "work started")
        let progress = IterationCounter()

        let caller = Task<Void, Never> {
            do {
                try await runCancellable {
                    started.fulfill()
                    // Stands in for the separators' per-chunk loop.
                    for _ in 0..<2_000 {
                        try Task.checkCancellation()
                        progress.increment()
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                } as Void
                XCTFail("The work should have been cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }

        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await caller.value

        XCTAssertLessThan(
            progress.value,
            2_000,
            "The work ran to completion, so cancellation never reached it"
        )
    }

    func testWorkThatFinishesFirstStillReturnsItsValue() async throws {
        let value = try await runCancellable { 6 * 7 }

        XCTAssertEqual(value, 42)
    }

    func testAnErrorFromTheWorkPropagatesToTheCaller() async {
        do {
            _ = try await runCancellable { throw WorkTestError.expected }
            XCTFail("The error should have propagated")
        } catch {
            XCTAssertTrue(error is WorkTestError)
        }
    }

    /// A caller that is already cancelled must not start a long job at all —
    /// or, if it has, must not wait for it to finish.
    func testAnAlreadyCancelledCallerDoesNotWaitForTheWork() async {
        let caller = Task<Void, Never> {
            do {
                try await runCancellable {
                    for _ in 0..<2_000 {
                        try Task.checkCancellation()
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                } as Void
            } catch {
                // Expected.
            }
        }
        caller.cancel()

        let start = Date()
        await caller.value

        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

private enum WorkTestError: Error { case expected }

private final class IterationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
