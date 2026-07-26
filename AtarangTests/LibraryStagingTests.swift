import AVFoundation
import XCTest
@testable import Atarang

final class LibraryStagingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStagingDirectoriesAreHiddenSoDiscoveryCannotSeeThem() throws {
        let staging = try LibraryStaging.makeDirectory(in: root)

        XCTAssertTrue(LibraryStaging.isStagingName(staging.lastPathComponent))
        XCTAssertTrue(staging.lastPathComponent.hasPrefix("."))
        let visible = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertTrue(visible.isEmpty)
    }

    func testCommitPublishesStagedContentUnderItsFinalName() throws {
        let staging = try LibraryStaging.makeDirectory(in: root)
        try Data("stem".utf8).write(to: staging.appendingPathComponent("vocals.wav"))
        let destination = root.appendingPathComponent("track", isDirectory: true)

        try LibraryStaging.commit(staging, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("vocals.wav")),
            Data("stem".utf8)
        )
    }

    func testCommitReplacesAnExistingEntryWholesale() throws {
        let destination = root.appendingPathComponent("track", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("vocals.wav"))
        try Data("stale".utf8).write(to: destination.appendingPathComponent("leftover.wav"))

        let staging = try LibraryStaging.makeDirectory(in: root)
        try Data("new".utf8).write(to: staging.appendingPathComponent("vocals.wav"))
        try LibraryStaging.commit(staging, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("vocals.wav")),
            Data("new".utf8)
        )
        // The replacement is the whole directory, so nothing from the previous
        // commit can survive alongside it and look like part of the new entry.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("leftover.wav").path
            )
        )
    }

    func testSweepRemovesAbandonedStagingButLeavesCommittedEntries() throws {
        let tracks = root.appendingPathComponent("Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        let abandoned = try LibraryStaging.makeDirectory(in: tracks)
        let committed = tracks.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: committed, withIntermediateDirectories: true)

        LibraryStaging.sweepAbandonedStaging(under: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.path))
    }

    func testSweepReachesStagingNestedUnderModels() throws {
        let model = root
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("kimVocals", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let abandoned = try LibraryStaging.makeDirectory(in: model)

        LibraryStaging.sweepAbandonedStaging(under: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    func testAudioDurationRejectsFilesThatAreNotAudio() throws {
        let bogus = root.appendingPathComponent("not-audio.caf")
        try Data("nonsense".utf8).write(to: bogus)

        XCTAssertNil(LibraryStaging.audioDuration(at: bogus))
        XCTAssertNil(LibraryStaging.audioDuration(at: root.appendingPathComponent("missing.caf")))
    }

    func testAudioDurationReportsTheLengthOfARealFile() throws {
        let url = root.appendingPathComponent("tone.caf")
        try AudioFixture.write(seconds: 1.5, to: url)

        let duration = try XCTUnwrap(LibraryStaging.audioDuration(at: url))
        XCTAssertEqual(duration, 1.5, accuracy: 0.01)
    }

    func testByteCountSumsARecursiveDirectory() throws {
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: folder.appendingPathComponent("a"))
        try Data(repeating: 0, count: 25).write(to: nested.appendingPathComponent("b"))

        XCTAssertEqual(LibraryStaging.byteCount(of: folder), 125)
        XCTAssertEqual(LibraryStaging.byteCount(of: root.appendingPathComponent("nope")), 0)
    }
}

/// Writes short real audio files, so the validation paths are exercised against
/// something AVFoundation will actually open.
enum AudioFixture {
    static func write(
        seconds: Double,
        to url: URL,
        sampleRate: Double = 44_100
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) {
            samples[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
        try file.write(from: buffer)
    }
}
