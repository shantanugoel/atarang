import AVFoundation
import XCTest
@testable import Atarang

/// The separators stopped loading the whole song and now pull overlapping
/// windows out of a stream. That is a memory change that must not be an output
/// change, so these tests hold the windows against the buffer the separators
/// used to slice.
final class PlanarAudioWindowTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    func testWindowsMatchSlicingTheWholeSong() throws {
        let url = try writeSong(frames: 3_300, sampleRate: 44_100)
        let whole = try AudioResampler.stereoFloat32(fileURL: url, sampleRate: 44_100)
        let reader = try PlanarAudioWindowReader(
            fileURL: url,
            sampleRate: 44_100,
            windowFrames: 1_000,
            hopFrames: 700
        )

        var start = 0
        var windows = 0
        while try reader.advance() {
            assertWindow(reader, matches: whole, sourceStart: start, label: "window \(windows)")
            windows += 1
            start += 700
            if reader.isAtEnd, reader.deliveredFrames - (start - 700) <= 1_000 { break }
        }

        XCTAssertEqual(reader.deliveredFrames, 3_300)
        // Starts at 0, 700, 1400, 2100, 2800 — the same set the old
        // `ceil((total - window) / hop) + 1` produced.
        XCTAssertEqual(windows, 5)
    }

    /// The MDX models centre their transform, so their first window starts half
    /// a transform before the song does and the audio there must be zero.
    func testLeadingPadPlacesTheSongAfterTheZeroes() throws {
        let url = try writeSong(frames: 2_048, sampleRate: 44_100)
        let whole = try AudioResampler.stereoFloat32(fileURL: url, sampleRate: 44_100)
        let pad = 128
        let reader = try PlanarAudioWindowReader(
            fileURL: url,
            sampleRate: 44_100,
            windowFrames: 512,
            hopFrames: 512 - 2 * pad,
            leadingPadFrames: pad
        )

        XCTAssertTrue(try reader.advance())
        XCTAssertEqual(reader.windowStart, -pad)
        for sample in 0..<pad {
            XCTAssertEqual(reader.planar[sample], 0)
            XCTAssertEqual(reader.planar[512 + sample], 0)
        }
        assertWindow(reader, matches: whole, sourceStart: -pad, label: "first window")

        XCTAssertTrue(try reader.advance())
        XCTAssertEqual(reader.windowStart, -pad + (512 - 2 * pad))
        assertWindow(reader, matches: whole, sourceStart: reader.windowStart, label: "second window")
    }

    /// Past the end of the song the window has to be silent, not stale audio
    /// left over from the previous hop.
    func testTheTailIsZeroedRatherThanRepeated() throws {
        let url = try writeSong(frames: 900, sampleRate: 44_100)
        let reader = try PlanarAudioWindowReader(
            fileURL: url,
            sampleRate: 44_100,
            windowFrames: 512,
            hopFrames: 512
        )

        XCTAssertTrue(try reader.advance())
        XCTAssertTrue(try reader.advance())
        XCTAssertEqual(reader.deliveredFrames, 900)
        for sample in (900 - 512)..<512 {
            XCTAssertEqual(reader.planar[sample], 0, "left sample \(sample)")
            XCTAssertEqual(reader.planar[512 + sample], 0, "right sample \(sample)")
        }
        XCTAssertFalse(try reader.advance())
    }

    func testASongShorterThanOneWindowStillProducesOne() throws {
        let url = try writeSong(frames: 100, sampleRate: 44_100)
        let reader = try PlanarAudioWindowReader(
            fileURL: url,
            sampleRate: 44_100,
            windowFrames: 512,
            hopFrames: 256
        )

        XCTAssertTrue(try reader.advance())
        XCTAssertEqual(reader.deliveredFrames, 100)
        XCTAssertFalse(try reader.advance())
    }

    /// Streaming has to resample identically to converting the file in one go,
    /// or slowed-down or 48 kHz sources would separate differently than before.
    func testResamplingThroughTheStreamMatchesTheOneShotConversion() throws {
        let url = try writeSong(frames: 4_096, sampleRate: 48_000)
        let whole = try AudioResampler.stereoFloat32(fileURL: url, sampleRate: 44_100)
        let stream = try ResampledAudioStream(fileURL: url, sampleRate: 44_100)

        var left = [Float](repeating: 0, count: Int(whole.frameLength))
        var right = [Float](repeating: 0, count: Int(whole.frameLength))
        var produced = 0
        try left.withUnsafeMutableBufferPointer { leftBuffer in
            try right.withUnsafeMutableBufferPointer { rightBuffer in
                // Deliberately awkward request sizes, so a block boundary lands
                // in the middle of a read.
                while produced < leftBuffer.count {
                    let read = try stream.read(
                        left: leftBuffer.baseAddress! + produced,
                        right: rightBuffer.baseAddress! + produced,
                        frames: min(333, leftBuffer.count - produced)
                    )
                    if read == 0 { break }
                    produced += read
                }
            }
        }

        XCTAssertEqual(produced, Int(whole.frameLength))
        let channels = whole.floatChannelData!
        for frame in 0..<produced {
            XCTAssertEqual(left[frame], channels[0][frame], accuracy: 1e-6)
            XCTAssertEqual(right[frame], channels[1][frame], accuracy: 1e-6)
        }
    }

    // MARK: - Helpers

    private func assertWindow(
        _ reader: PlanarAudioWindowReader,
        matches whole: AVAudioPCMBuffer,
        sourceStart: Int,
        label: String
    ) {
        let channels = whole.floatChannelData!
        let total = Int(whole.frameLength)
        for sample in 0..<reader.windowFrames {
            let source = sourceStart + sample
            let expectedLeft = (0..<total).contains(source) ? channels[0][source] : 0
            let expectedRight = (0..<total).contains(source) ? channels[1][source] : 0
            XCTAssertEqual(
                reader.planar[sample], expectedLeft, accuracy: 1e-6,
                "\(label) left \(sample)"
            )
            XCTAssertEqual(
                reader.planar[reader.windowFrames + sample], expectedRight, accuracy: 1e-6,
                "\(label) right \(sample)"
            )
        }
    }

    private func writeSong(frames: Int, sampleRate: Double) throws -> URL {
        let url = library.url.appendingPathComponent("song-\(UUID().uuidString).wav")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
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
            channels[0][frame] = Float(sin(Double(frame) * 0.017)) * 0.5
            channels[1][frame] = Float(cos(Double(frame) * 0.023)) * 0.4
        }
        try file.write(from: buffer)
        return url
    }
}
