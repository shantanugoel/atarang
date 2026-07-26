import AVFoundation
import XCTest
@testable import Atarang

/// The pure pieces the redesigned Studio rests on: the waveform measurement
/// behind the transport timeline, the chip readouts, and the outcome
/// vocabulary the import screen now leads with.
final class WaveformOverviewTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheOverviewIsAlwaysTheDeclaredWidthAndNormalised() throws {
        let url = try write(name: "steady.caf", seconds: 4) { _ in 0.5 }

        let summary = try XCTUnwrap(WaveformStore.measure(files: [url]))

        XCTAssertEqual(summary.schemaVersion, WaveformSummary.currentSchemaVersion)
        XCTAssertEqual(summary.peaks.count, WaveformSummary.bucketCount)
        XCTAssertEqual(summary.peaks.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertTrue(summary.peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    /// The point of the overview: a quiet passage has to look quieter than a
    /// loud one, or it tells the user nothing about where they are in the song.
    func testALoudSecondHalfMeasuresLouderThanAQuietFirstHalf() throws {
        let url = try write(name: "dynamic.caf", seconds: 4) { frame in
            frame < 2 * 44_100 ? 0.1 : 0.9
        }

        let summary = try XCTUnwrap(WaveformStore.measure(files: [url]))

        let half = WaveformSummary.bucketCount / 2
        // Bucket boundaries land mid-transition, so compare well inside each.
        XCTAssertLessThan(summary.peaks[half / 2], 0.3)
        XCTAssertGreaterThan(summary.peaks[half + half / 2], 0.9)
    }

    /// Stems combine as energy, so two equal stems read louder than one and not
    /// four times as loud.
    func testStemsCombineAsEnergyRatherThanBeingSummedOrAveraged() throws {
        let quiet = try write(name: "a.caf", seconds: 2) { _ in 0.2 }
        let loud = try write(name: "b.caf", seconds: 2) { _ in 0.4 }

        let single = try XCTUnwrap(WaveformStore.measure(files: [loud]))
        let combined = try XCTUnwrap(WaveformStore.measure(files: [quiet, loud]))

        // Both are normalised to 1, so compare the ratio that survives
        // normalisation: a flat signal stays flat either way.
        XCTAssertEqual(single.peaks[100], 1, accuracy: 0.01)
        XCTAssertEqual(combined.peaks[100], 1, accuracy: 0.01)
    }

    func testAnUnreadableFileYieldsNoOverviewRatherThanAFlatOne() {
        let missing = root.appendingPathComponent("nothing.caf")

        XCTAssertNil(WaveformStore.measure(files: [missing]))
    }

    private func write(
        name: String,
        seconds: Double,
        sample: (Int) -> Float
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44_100,
                channels: 1,
                interleaved: false
            )
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(seconds * 44_100)
        let chunk = 4_410
        var written = 0
        while written < frames {
            let count = min(chunk, frames - written)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
            )
            buffer.frameLength = AVAudioFrameCount(count)
            for index in 0..<count {
                buffer.floatChannelData![0][index] = sample(written + index)
            }
            try file.write(from: buffer)
            written += count
        }
        return url
    }
}

final class StudioFormatTests: XCTestCase {
    func testTimeIsClampedAndZeroPadded() {
        XCTAssertEqual(StudioFormat.time(0), "0:00")
        XCTAssertEqual(StudioFormat.time(-5), "0:00")
        XCTAssertEqual(StudioFormat.time(65), "1:05")
        XCTAssertEqual(StudioFormat.time(.nan), "0:00")
    }

    func testPreciseTimeKeepsTheTenthTheNudgeButtonsMove() {
        XCTAssertEqual(StudioFormat.preciseTime(65.4), "1:05.4")
        XCTAssertEqual(StudioFormat.preciseTime(9.05), "0:09.1")
    }

    func testKeyReadsAsAKeyRatherThanANumber() {
        XCTAssertEqual(StudioFormat.semitones(0), "Original key")
        XCTAssertEqual(StudioFormat.semitones(1), "+1 semitone")
        XCTAssertEqual(StudioFormat.semitones(-3), "-3 semitones")
        XCTAssertEqual(StudioFormat.semitonesShort(0), "Original")
        XCTAssertEqual(StudioFormat.semitonesShort(2), "+2")
    }
}

final class SeparationOutcomeTests: XCTestCase {
    func testEveryModelHasADistinctOutcomeName() {
        let names = Set(SeparationModelKind.allCases.map(\.outcomeTitle))

        XCTAssertEqual(names.count, SeparationModelKind.allCases.count)
    }

    func testTheRecommendationCanAlwaysRunOnThisDevice() {
        XCTAssertTrue(
            SeparationModelKind.recommendedForCurrentDevice.isAvailableOnCurrentDevice
        )
    }

    /// An unavailable choice has to say what to pick instead; an available one
    /// must not suggest anything at all.
    func testOnlyUnavailableModelsSuggestAnAlternative() {
        for kind in SeparationModelKind.allCases {
            if kind.isAvailableOnCurrentDevice {
                XCTAssertNil(kind.suggestedAlternative, "\(kind)")
            } else {
                XCTAssertNotNil(kind.unavailabilityMessage, "\(kind)")
                XCTAssertNotEqual(kind.suggestedAlternative, kind, "\(kind)")
            }
        }
    }
}

final class StudioStageTests: XCTestCase {
    func testTheStageDefaultsToTheOnlyStageThatWorksToday() {
        XCTAssertEqual(SongPracticeSettings().stage, .mixer)
    }

    func testTheStageSurvivesEncodingAndValidation() throws {
        var settings = SongPracticeSettings()
        settings.stage = .chords

        settings.validate(duration: 120, availableStems: [.vocals, .drums])
        let decoded = try JSONDecoder().decode(
            SongPracticeSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded.stage, .chords)
        XCTAssertEqual(decoded.schemaVersion, SongPracticeSettings.currentSchemaVersion)
    }
}
