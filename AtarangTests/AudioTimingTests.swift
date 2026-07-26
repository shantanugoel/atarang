import AVFoundation
import XCTest
@testable import Atarang

final class StemSchedulingTests: XCTestCase {
    private let stereo44k = StemFileGeometry(length: 441_000, sampleRate: 44_100)

    func testSegmentCoversTheRequestedSourceRange() {
        let segment = StemScheduling.segment(for: stereo44k, from: 2, to: 5)

        XCTAssertEqual(segment.startingFrame, 88_200)
        XCTAssertEqual(segment.frameCount, 132_300)
        XCTAssertFalse(segment.isEmpty)
    }

    func testStemsAtDifferentSampleRatesCoverTheSameSourceSeconds() {
        let at48k = StemFileGeometry(length: 480_000, sampleRate: 48_000)

        let a = StemScheduling.segment(for: stereo44k, from: 3, to: 7)
        let b = StemScheduling.segment(for: at48k, from: 3, to: 7)

        XCTAssertEqual(Double(a.startingFrame) / 44_100, 3, accuracy: 0.0001)
        XCTAssertEqual(Double(b.startingFrame) / 48_000, 3, accuracy: 0.0001)
        XCTAssertEqual(Double(a.frameCount) / 44_100, 4, accuracy: 0.0001)
        XCTAssertEqual(Double(b.frameCount) / 48_000, 4, accuracy: 0.0001)
    }

    func testSegmentIsClampedToTheFileLength() {
        let segment = StemScheduling.segment(for: stereo44k, from: 8, to: 30)

        XCTAssertEqual(segment.startingFrame, 352_800)
        XCTAssertEqual(segment.frameCount, 88_200)
    }

    func testSegmentIsEmptyPastTheEndOfTheFile() {
        XCTAssertTrue(StemScheduling.segment(for: stereo44k, from: 12, to: 20).isEmpty)
        XCTAssertTrue(StemScheduling.segment(for: stereo44k, from: 3, to: 3).isEmpty)
    }

    func testSegmentRejectsNonsenseGeometry() {
        let broken = StemFileGeometry(length: 441_000, sampleRate: 0)

        XCTAssertTrue(StemScheduling.segment(for: broken, from: 0, to: 5).isEmpty)
    }

    func testTimingStemPrefersTheFirstActiveStem() {
        let stems: [StemKind] = [.vocals, .drums, .bass, .other]

        let timing = StemScheduling.timingStem(
            among: stems,
            geometry: { _ in self.stereo44k },
            from: 0,
            to: 10
        )

        XCTAssertEqual(timing, .vocals)
    }

    func testTimingStemFallsThroughAStemThatSchedulesNoFrames() {
        let truncated = StemFileGeometry(length: 0, sampleRate: 44_100)
        let stems: [StemKind] = [.vocals, .drums, .bass]

        let timing = StemScheduling.timingStem(
            among: stems,
            geometry: { stem in stem == .vocals ? truncated : self.stereo44k },
            from: 0,
            to: 10
        )

        XCTAssertEqual(timing, .drums)
    }

    func testTimingStemFallsThroughAStemThatEndsBeforeTheRange() {
        let short = StemFileGeometry(length: 44_100, sampleRate: 44_100)
        let stems: [StemKind] = [.vocals, .drums]

        let timing = StemScheduling.timingStem(
            among: stems,
            geometry: { stem in stem == .vocals ? short : self.stereo44k },
            from: 4,
            to: 8
        )

        XCTAssertEqual(timing, .drums)
    }

    func testTimingStemIsNilWhenNoStemCanSchedule() {
        let timing = StemScheduling.timingStem(
            among: [.vocals, .drums],
            geometry: { _ in StemFileGeometry(length: 0, sampleRate: 44_100) },
            from: 0,
            to: 10
        )

        XCTAssertNil(timing)
    }

    func testTimingStemIgnoresStemsWithNoFile() {
        let timing = StemScheduling.timingStem(
            among: [.vocals, .drums],
            geometry: { stem in stem == .drums ? self.stereo44k : nil },
            from: 0,
            to: 10
        )

        XCTAssertEqual(timing, .drums)
    }
}

final class MetronomeClickPlanTests: XCTestCase {
    private func plan(
        start: TimeInterval = 0,
        end: TimeInterval = 60,
        renderOrigin: TimeInterval = 0,
        bpm: Double = 120,
        clicksPerBeat: Int = 1,
        alignment: TimeInterval = 0,
        accents: Bool = true,
        rate: Double = 1
    ) -> MetronomeClickPlan {
        var plan = MetronomeClickPlan(
            sourceStart: start,
            sourceEnd: end,
            renderOrigin: renderOrigin,
            bpm: bpm,
            clicksPerBeat: clicksPerBeat,
            alignment: alignment,
            accentsEnabled: accents,
            rate: rate
        )
        plan.reset()
        return plan
    }

    func testClicksLandOnTheBeatGrid() {
        var plan = plan()

        let clicks = plan.clicks(through: 2.5)

        XCTAssertEqual(clicks.map(\.sourceTime), [0, 0.5, 1, 1.5, 2, 2.5])
        XCTAssertEqual(clicks.map(\.renderTime), [0, 0.5, 1, 1.5, 2, 2.5])
    }

    func testOnlyTheWindowIsScheduledAndTheCursorAdvances() {
        var plan = plan()

        let first = plan.clicks(through: 1)
        let second = plan.clicks(through: 2)

        XCTAssertEqual(first.map(\.sourceTime), [0, 0.5, 1])
        XCTAssertEqual(second.map(\.sourceTime), [1.5, 2])
        XCTAssertTrue(plan.clicks(through: 1).isEmpty)
    }

    func testClicksStopAtTheEndOfThePass() {
        var plan = plan(start: 0, end: 1)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(clicks.map(\.sourceTime), [0, 0.5])
    }

    func testSlowerPlaybackStretchesRenderTimeButNotSourceTime() {
        var plan = plan(rate: 0.5)

        let clicks = plan.clicks(through: 4)

        XCTAssertEqual(clicks.map(\.sourceTime), [0, 0.5, 1, 1.5, 2])
        XCTAssertEqual(clicks.map(\.renderTime), [0, 1, 2, 3, 4])
    }

    func testAPassStartingMidSongBeginsAtItsFirstClick() {
        var plan = plan(start: 10.2, end: 12, renderOrigin: 30)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(clicks.first?.sourceTime, 10.5)
        XCTAssertEqual(clicks.first?.renderTime ?? 0, 30.3, accuracy: 0.0001)
        XCTAssertTrue(clicks.allSatisfy { $0.sourceTime >= 10.2 })
    }

    func testEveryFourthBeatIsAccented() {
        var plan = plan(end: 5)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(
            clicks.filter(\.isAccented).map(\.sourceTime),
            [0, 2, 4]
        )
    }

    func testSubdivisionsAreNotAccented() {
        var plan = plan(end: 2, clicksPerBeat: 2)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(clicks.map(\.sourceTime), [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75])
        XCTAssertEqual(clicks.filter(\.isAccented).map(\.sourceTime), [0])
    }

    func testAccentsCanBeDisabled() {
        var plan = plan(end: 5, accents: false)

        XCTAssertTrue(plan.clicks(through: 100).allSatisfy { !$0.isAccented })
    }

    func testAlignmentShiftsTheGridInBothDirections() {
        // Aligning the downbeat at 0.75 s keeps clicking before it too, so a
        // song whose first beat is late still gets a full click track.
        var plan = plan(start: 0, end: 3, alignment: 0.75)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(clicks.map(\.sourceTime), [0.25, 0.75, 1.25, 1.75, 2.25, 2.75])
        XCTAssertEqual(clicks.filter(\.isAccented).map(\.sourceTime), [0.75, 2.75])
    }

    func testTheAlignedBeatIsTheAccentedOne() {
        var plan = plan(start: 0, end: 2, alignment: 1)

        let clicks = plan.clicks(through: 100)

        XCTAssertEqual(clicks.map(\.sourceTime), [0, 0.5, 1, 1.5])
        XCTAssertEqual(clicks.filter(\.isAccented).map(\.sourceTime), [1])
    }

    func testInvalidPlansProduceNothing() {
        var stopped = plan(rate: 0)
        var backwards = plan(start: 5, end: 5)
        var zeroBPM = plan(bpm: 0)

        XCTAssertTrue(stopped.clicks(through: 100).isEmpty)
        XCTAssertTrue(backwards.clicks(through: 100).isEmpty)
        XCTAssertTrue(zeroBPM.clicks(through: 100).isEmpty)
    }

    func testAWholeSongIsNotEnumeratedForASmallWindow() {
        // The point of the rolling window: a nine-minute track at 120 BPM must
        // not cost 1,080 clicks up front.
        var plan = plan(end: 540)

        XCTAssertEqual(plan.clicks(through: 3).count, 7)
    }
}

final class WriteThrottleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testTheFirstWriteAlwaysPassesThrough() {
        var throttle = WriteThrottle(interval: 2)

        XCTAssertTrue(throttle.shouldWrite(now: start))
        XCTAssertFalse(throttle.hasPendingWrite)
    }

    func testASecondWriteInsideTheIntervalIsSuppressedAndRemembered() {
        var throttle = WriteThrottle(interval: 2)
        _ = throttle.shouldWrite(now: start)

        XCTAssertFalse(throttle.shouldWrite(now: start.addingTimeInterval(0.1)))
        XCTAssertTrue(throttle.hasPendingWrite)
    }

    func testOneSeekCostsOneWriteNotTwo() {
        // `seek` persists once itself and once through `pausePlayback`.
        var throttle = WriteThrottle(interval: 2)
        var writes = 0
        for _ in 0..<2 where throttle.shouldWrite(now: start) { writes += 1 }

        XCTAssertEqual(writes, 1)
    }

    func testTenSeeksInOneSecondProduceOneWrite() {
        var throttle = WriteThrottle(interval: 2)
        var writes = 0
        for step in 0..<20 {
            let now = start.addingTimeInterval(Double(step) * 0.05)
            if throttle.shouldWrite(now: now) { writes += 1 }
        }

        XCTAssertEqual(writes, 1)
        XCTAssertTrue(throttle.hasPendingWrite)
    }

    func testAWriteIsAllowedAgainAfterTheInterval() {
        var throttle = WriteThrottle(interval: 2)
        _ = throttle.shouldWrite(now: start)

        XCTAssertTrue(throttle.shouldWrite(now: start.addingTimeInterval(2)))
        XCTAssertFalse(throttle.hasPendingWrite)
    }

    func testForcingBypassesTheIntervalAndClearsThePendingWrite() {
        var throttle = WriteThrottle(interval: 2)
        _ = throttle.shouldWrite(now: start)
        _ = throttle.shouldWrite(now: start.addingTimeInterval(0.1))

        XCTAssertTrue(
            throttle.shouldWrite(now: start.addingTimeInterval(0.2), force: true)
        )
        XCTAssertFalse(throttle.hasPendingWrite)
    }

    func testTheFlushDelayCountsDownFromTheLastWrite() {
        var throttle = WriteThrottle(interval: 2)
        _ = throttle.shouldWrite(now: start)

        XCTAssertEqual(
            throttle.delayUntilNextWrite(now: start.addingTimeInterval(0.5)),
            1.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            throttle.delayUntilNextWrite(now: start.addingTimeInterval(5)),
            0
        )
    }

    func testResetLetsTheNextWriteThroughImmediately() {
        var throttle = WriteThrottle(interval: 2)
        _ = throttle.shouldWrite(now: start)
        _ = throttle.shouldWrite(now: start.addingTimeInterval(0.1))
        throttle.reset()

        XCTAssertFalse(throttle.hasPendingWrite)
        XCTAssertTrue(throttle.shouldWrite(now: start.addingTimeInterval(0.2)))
    }
}
