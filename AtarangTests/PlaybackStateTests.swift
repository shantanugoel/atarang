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

    func testRateAwarePositionUsesRenderedSamples() {
        var state = PlaybackState()
        state.load(duration: 100)
        state.seek(to: 10)
        state.setRate(0.5)

        let position = state.calculatedPosition(
            renderSampleTime: 96_000,
            sampleRate: 48_000,
            anchorPosition: state.position
        )

        XCTAssertEqual(position, 11, accuracy: 0.000_001)
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
