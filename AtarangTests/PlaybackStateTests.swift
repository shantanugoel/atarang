import XCTest
@testable import Atarang

final class PlaybackStateTests: XCTestCase {
    func testLoopRangeValidationAndClamping() {
        XCTAssertNil(PlaybackLoopRange(start: 4, end: 4, duration: 10))
        XCTAssertNil(PlaybackLoopRange(start: 5, end: 4, duration: 10))
        XCTAssertNil(PlaybackLoopRange(start: .nan, end: 4, duration: 10))

        let range = PlaybackLoopRange(start: -2, end: 12, duration: 10)
        XCTAssertEqual(range, PlaybackLoopRange(start: 0, end: 10, duration: 10))
    }

    /// The player node's frames are song seconds at every speed, because the
    /// time-pitch unit pulls the node more slowly rather than the node
    /// producing fewer frames. Two seconds of node time is two seconds of song
    /// whether the rate is 1.0 or 0.5; only the wall clock differs.
    func testRenderedSamplesAreSongSecondsAtEverySpeed() {
        for rate in [Float(1), 0.75, 0.5] {
            var state = PlaybackState()
            state.load(duration: 100)
            state.seek(to: 10)
            state.setRate(rate)

            let position = state.calculatedPosition(
                renderSampleTime: 96_000,
                sampleRate: 48_000,
                anchorPosition: state.position
            )

            XCTAssertEqual(position, 12, accuracy: 0.000_001, "rate \(rate)")
        }
    }

    /// The regression this replaces: the playhead advanced at half its true
    /// speed at 0.5×, and the old test asserted that wrong value.
    func testPositionKeepsPaceWithTheSongAtHalfSpeed() {
        var state = PlaybackState()
        state.load(duration: 100)
        state.setRate(0.5)

        // Ten seconds of wall clock at 0.5× consumes five seconds of song, and
        // the node reports those five seconds.
        let position = state.calculatedPosition(
            renderSampleTime: 240_000,
            sampleRate: 48_000,
            anchorPosition: 0
        )

        XCTAssertEqual(position, 5, accuracy: 0.000_001)
    }

    func testRenderedPositionWrapsAtLoopBoundary() {
        var state = PlaybackState()
        state.load(duration: 20)
        XCTAssertTrue(state.setLoop(start: 2, end: 4))

        let position = state.calculatedPosition(
            renderSampleTime: 240_000,
            sampleRate: 48_000,
            anchorPosition: 2
        )

        XCTAssertEqual(position, 3, accuracy: 0.000_001)
    }

    func testOutputLatencyIsSubtractedFromTheReportedPosition() {
        var state = PlaybackState()
        state.load(duration: 100)

        let uncompensated = state.calculatedPosition(
            renderSampleTime: 48_000,
            sampleRate: 48_000,
            anchorPosition: 10
        )
        let compensated = state.calculatedPosition(
            renderSampleTime: 48_000,
            sampleRate: 48_000,
            anchorPosition: 10,
            outputLatency: 0.15
        )

        XCTAssertEqual(uncompensated, 11, accuracy: 0.000_001)
        XCTAssertEqual(compensated, 10.85, accuracy: 0.000_001)
    }

    func testLatencyCompensationIsExpressedInSourceSeconds() {
        // At half speed a 200 ms output delay is only 100 ms of song.
        var state = PlaybackState()
        state.load(duration: 100)
        state.setRate(0.5)

        let position = state.calculatedPosition(
            renderSampleTime: 96_000,
            sampleRate: 48_000,
            anchorPosition: 10,
            outputLatency: 0.2
        )

        XCTAssertEqual(position, 11.9, accuracy: 0.000_001)
    }

    func testLatencyCompensationNeverRunsThePositionBackwards() {
        var state = PlaybackState()
        state.load(duration: 100)
        state.seek(to: 10)

        let position = state.calculatedPosition(
            renderSampleTime: 480,
            sampleRate: 48_000,
            anchorPosition: 10,
            outputLatency: 0.25
        )

        XCTAssertEqual(position, 10, accuracy: 0.000_001)
    }

    func testInvalidLatencyIsIgnored() {
        var state = PlaybackState()
        state.load(duration: 100)

        for latency in [TimeInterval.nan, -1, .infinity] {
            XCTAssertEqual(
                state.calculatedPosition(
                    renderSampleTime: 48_000,
                    sampleRate: 48_000,
                    anchorPosition: 10,
                    outputLatency: latency
                ),
                11,
                accuracy: 0.000_001
            )
        }
    }

    func testChangingLoopStartsANewPlaybackGeneration() {
        var state = PlaybackState()
        state.load(duration: 20)
        let initialGeneration = state.playbackGeneration

        XCTAssertTrue(state.setLoop(start: 2, end: 4))
        XCTAssertGreaterThan(state.playbackGeneration, initialGeneration)
        let loopGeneration = state.playbackGeneration

        state.clearLoop()
        XCTAssertGreaterThan(state.playbackGeneration, loopGeneration)
    }

    func testTransformsAreClampedToSupportedRanges() {
        var state = PlaybackState()
        state.load(duration: 100)

        state.seek(to: 120)
        state.setRate(2)
        state.setPitchSemitones(30)

        XCTAssertEqual(state.position, 100)
        XCTAssertEqual(state.rate, PlaybackState.supportedRateRange.upperBound)
        XCTAssertEqual(
            state.pitchSemitones,
            PlaybackState.supportedPitchRange.upperBound
        )
    }
}
