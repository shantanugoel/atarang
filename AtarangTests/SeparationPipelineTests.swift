import AVFoundation
import XCTest
@testable import Atarang

/// Runs the bundled 4-stem model end to end.
///
/// The chunk loop stopped being driven by a frame count computed up front and
/// is now driven by the stream running out, which is exactly the kind of change
/// that unit tests around the pieces can miss: every window can be correct and
/// the song can still end up a chunk short. This separates a real file with the
/// real model and checks what lands on disk.
final class SeparationPipelineTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    func testTheBundledModelSeparatesASongToItsOwnLength() async throws {
        guard let modelURL = Bundle.main.url(
            forResource: SeparationModelKind.htdemucs.resourceName,
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: SeparationModelKind.htdemucs.resourceName,
            withExtension: "mlpackage"
        ) else {
            throw XCTSkip("The bundled 4-stem model is not in this test host.")
        }

        let frames = 132_300 // three seconds
        let songURL = try writeSong(frames: frames)
        let output = library.folder(named: "stems")
        let separator = try CoreMLWaveformSeparator(
            modelKind: .htdemucs,
            modelURL: modelURL
        )

        let progress = ProgressRecorder()
        let files = try await separator.separate(
            fileURL: songURL,
            outputFolder: output
        ) { progress.record($0) }

        XCTAssertEqual(Set(files.keys), Set(SeparationModelKind.htdemucs.stems))
        // The loop no longer knows its chunk count up front, so reaching 1 is
        // the signal that it recognised the final chunk as final.
        XCTAssertEqual(progress.highest, 1, accuracy: 0.0001)
        for stem in SeparationModelKind.htdemucs.stems {
            let url = try XCTUnwrap(files[stem])
            let file = try AVAudioFile(forReading: url)
            // Not "about the right length": a streaming loop that stops one
            // chunk early loses seconds off the end of every stem, and it would
            // still sound like a separation.
            XCTAssertEqual(file.length, Int64(frames), "\(stem.rawValue) length")
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            XCTAssertTrue(isFinite(file), "\(stem.rawValue) contains NaN or infinity")
        }
    }

    /// A song shorter than one chunk still has to come out whole.
    func testASongShorterThanOneChunkSeparatesCompletely() async throws {
        guard let modelURL = Bundle.main.url(
            forResource: SeparationModelKind.htdemucs.resourceName,
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: SeparationModelKind.htdemucs.resourceName,
            withExtension: "mlpackage"
        ) else {
            throw XCTSkip("The bundled 4-stem model is not in this test host.")
        }

        let frames = 22_050 // half a second
        let songURL = try writeSong(frames: frames)
        let output = library.folder(named: "short")
        let separator = try CoreMLWaveformSeparator(
            modelKind: .htdemucs,
            modelURL: modelURL
        )

        let files = try await separator.separate(
            fileURL: songURL,
            outputFolder: output
        ) { _ in }

        for stem in SeparationModelKind.htdemucs.stems {
            let url = try XCTUnwrap(files[stem])
            XCTAssertEqual(try AVAudioFile(forReading: url).length, Int64(frames))
        }
    }

    // MARK: - Helpers

    /// The progress callback is `@Sendable` and arrives from the separator's
    /// own task.
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0.0

        func record(_ reported: Double) {
            lock.lock()
            defer { lock.unlock() }
            value = max(value, reported)
        }

        var highest: Double {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func isFinite(_ file: AVAudioFile) -> Bool {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ), (try? file.read(into: buffer)) != nil,
           let channels = buffer.floatChannelData else { return false }
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) where !channels[channel][frame].isFinite {
                return false
            }
        }
        return true
    }

    private func writeSong(frames: Int) throws -> URL {
        let url = library.url.appendingPathComponent("song-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = buffer.floatChannelData!
        for frame in 0..<frames {
            let time = Double(frame) / 44_100
            // A low note and a bright overtone, so the model has something to
            // pull apart rather than noise.
            let bass = sin(2 * .pi * 110 * time) * 0.4
            let lead = sin(2 * .pi * 880 * time) * 0.2
            channels[0][frame] = Float(bass + lead)
            channels[1][frame] = Float(bass - lead)
        }
        try file.write(from: buffer)
        return url
    }
}
