import XCTest
@testable import Atarang

final class SerialLaneTests: XCTestCase {
    /// An actor alone would not give this: awaiting inside an actor method lets
    /// the next caller in, which is exactly what the lane must prevent.
    func testWorkRunsOneAtATime() async throws {
        let lane = SerialLane()
        let tracker = OverlapTracker()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? await lane.run {
                        await tracker.enter()
                        try? await Task.sleep(for: .milliseconds(10))
                        await tracker.leave()
                    }
                }
            }
        }

        let peak = await tracker.peakConcurrency
        let completed = await tracker.completed
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(completed, 8)
    }

    func testWorkRunsInSubmissionOrder() async throws {
        let lane = SerialLane()
        let tracker = OverlapTracker()
        var tasks: [Task<Void, Never>] = []

        for index in 0..<5 {
            // Submitted in order, with a gap so each `run` is entered before
            // the next is created.
            let task = Task<Void, Never> {
                _ = try? await lane.run { await tracker.record(index) }
            }
            tasks.append(task)
            try await Task.sleep(for: .milliseconds(5))
        }
        for task in tasks { await task.value }

        let order = await tracker.order
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
    }

    func testAFailedItemDoesNotStallTheLane() async throws {
        let lane = SerialLane()

        do {
            _ = try await lane.run { throw LaneTestError.expected }
            XCTFail("The error should have propagated to the caller")
        } catch {
            XCTAssertTrue(error is LaneTestError)
        }

        let value = try await lane.run { 42 }
        XCTAssertEqual(value, 42)
    }
}

private enum LaneTestError: Error { case expected }

private actor OverlapTracker {
    private var active = 0
    private(set) var peakConcurrency = 0
    private(set) var completed = 0
    private(set) var order: [Int] = []

    func enter() {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
    }

    func leave() {
        active -= 1
        completed += 1
    }

    func record(_ index: Int) {
        order.append(index)
    }
}
