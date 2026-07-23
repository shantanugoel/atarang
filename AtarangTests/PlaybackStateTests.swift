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

    func testLegacyPersistedStateMigratesMissingTransformFields() throws {
        let legacyJSON = Data(#"{"position":12,"duration":100}"#.utf8)
        let state = try JSONDecoder().decode(PlaybackState.self, from: legacyJSON)

        XCTAssertEqual(state.schemaVersion, PlaybackState.currentSchemaVersion)
        XCTAssertEqual(state.position, 12)
        XCTAssertEqual(state.duration, 100)
        XCTAssertEqual(state.rate, 1)
        XCTAssertEqual(state.pitchSemitones, 0)
        XCTAssertNil(state.loopRange)
        XCTAssertEqual(state.playbackGeneration, 0)
    }

    func testPersistedValuesAreClampedDuringMigration() throws {
        let legacyJSON = Data(
            #"{"position":120,"duration":100,"rate":2,"pitchSemitones":30}"#.utf8
        )
        let state = try JSONDecoder().decode(PlaybackState.self, from: legacyJSON)

        XCTAssertEqual(state.position, 100)
        XCTAssertEqual(state.rate, PlaybackState.supportedRateRange.upperBound)
        XCTAssertEqual(
            state.pitchSemitones,
            PlaybackState.supportedPitchRange.upperBound
        )
    }
}
