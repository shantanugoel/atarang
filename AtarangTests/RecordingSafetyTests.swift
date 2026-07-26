import AVFoundation
import XCTest
@testable import Atarang

final class AudioTapFileWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TapWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBuffersWrittenThroughTheQueueLandInTheFile() throws {
        let url = root.appendingPathComponent("captured.caf")
        let writer = AudioTapFileWriter(url: url)

        for _ in 0..<10 { writer.write(Self.buffer(frames: 4_410)) }
        XCTAssertNil(writer.finish())

        let duration = try XCTUnwrap(LibraryStaging.audioDuration(at: url))
        XCTAssertEqual(duration, 1.0, accuracy: 0.01)
    }

    func testACopiedBufferKeepsItsSamples() throws {
        let source = Self.buffer(frames: 512, value: 0.25)

        let copy = try XCTUnwrap(AudioTapFileWriter.copy(source))

        XCTAssertEqual(copy.frameLength, source.frameLength)
        XCTAssertEqual(copy.floatChannelData![0][0], 0.25)
        XCTAssertEqual(copy.floatChannelData![0][511], 0.25)
    }

    /// The bug this whole path exists for: a failed write used to be printed
    /// and ignored, and the take was committed anyway.
    func testAFailedWriteIsReportedAndRemembered() throws {
        let unwritable = root
            .appendingPathComponent("missing-directory", isDirectory: true)
            .appendingPathComponent("captured.caf")
        let writer = AudioTapFileWriter(url: unwritable)
        let reported = expectation(description: "failure reported")
        let box = FailureBox()
        writer.setFailureHandler { error in
            box.store(error)
            reported.fulfill()
        }

        writer.write(Self.buffer(frames: 512))
        wait(for: [reported], timeout: 5)

        XCTAssertNotNil(box.value)
        XCTAssertNotNil(writer.finish())
    }

    func testTheFailureHandlerIsCalledOnceEvenAcrossManyFailedBuffers() throws {
        let unwritable = root
            .appendingPathComponent("missing-directory", isDirectory: true)
            .appendingPathComponent("captured.caf")
        let writer = AudioTapFileWriter(url: unwritable)
        let reported = expectation(description: "failure reported")
        let counter = CallCounter()
        writer.setFailureHandler { _ in
            counter.increment()
            reported.fulfill()
        }

        for _ in 0..<20 { writer.write(Self.buffer(frames: 512)) }
        wait(for: [reported], timeout: 5)
        writer.finish()

        XCTAssertEqual(counter.value, 1)
    }

    /// A handler attached after the failure has already happened still hears
    /// about it, so a race at the start of a take cannot swallow the report.
    func testAFailureThatPrecedesTheHandlerIsStillDelivered() throws {
        let unwritable = root
            .appendingPathComponent("missing-directory", isDirectory: true)
            .appendingPathComponent("captured.caf")
        let writer = AudioTapFileWriter(url: unwritable)
        writer.write(Self.buffer(frames: 512))
        // Let the queue attempt the write.
        XCTAssertNotNil(writer.finish())

        let reported = expectation(description: "failure reported")
        writer.setFailureHandler { _ in reported.fulfill() }
        wait(for: [reported], timeout: 5)
    }

    private static func buffer(frames: AVAudioFrameCount, value: Float = 0.1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frames) { samples[frame] = value }
        return buffer
    }
}

final class StagedTakeValidationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedTakeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testATakeWithBothStreamsIsAcceptedAtTheShorterDuration() throws {
        let microphone = root.appendingPathComponent("microphone.caf")
        let backing = root.appendingPathComponent("backing.caf")
        try AudioFixture.write(seconds: 4, to: microphone)
        try AudioFixture.write(seconds: 4.2, to: backing)

        let duration = try XCTUnwrap(
            StemPlayer.validateStagedTake(microphoneURL: microphone, backingURL: backing)
        )
        XCTAssertEqual(duration, 4, accuracy: 0.01)
    }

    func testATakeMissingOneStreamIsRejected() throws {
        let microphone = root.appendingPathComponent("microphone.caf")
        try AudioFixture.write(seconds: 4, to: microphone)

        XCTAssertNil(
            StemPlayer.validateStagedTake(
                microphoneURL: microphone,
                backingURL: root.appendingPathComponent("backing.caf")
            )
        )
    }

    func testAnEffectivelyEmptyTakeIsRejected() throws {
        let microphone = root.appendingPathComponent("microphone.caf")
        let backing = root.appendingPathComponent("backing.caf")
        try AudioFixture.write(seconds: 0.05, to: microphone)
        try AudioFixture.write(seconds: 0.05, to: backing)

        XCTAssertNil(
            StemPlayer.validateStagedTake(microphoneURL: microphone, backingURL: backing)
        )
    }

    /// One stream stopping early is the shape a mid-take writer failure leaves
    /// behind, and it must not be published as a valid performance.
    func testStreamsThatDisagreeAboutTheTakeLengthAreRejected() throws {
        let microphone = root.appendingPathComponent("microphone.caf")
        let backing = root.appendingPathComponent("backing.caf")
        try AudioFixture.write(seconds: 2, to: microphone)
        try AudioFixture.write(seconds: 30, to: backing)

        XCTAssertNil(
            StemPlayer.validateStagedTake(microphoneURL: microphone, backingURL: backing)
        )
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
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
