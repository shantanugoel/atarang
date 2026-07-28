import Accelerate
import XCTest
@testable import Atarang

/// `MDXSpectralTransform` moved from a complex-to-complex DFT with a
/// hand-written conjugate mirror to `vDSP_DFT_zrop`, whose packing and scaling
/// conventions are easy to get subtly wrong — a wrong factor of two or a
/// misplaced Nyquist bin would still produce plausible-sounding audio. These
/// tests hold it against a direct DFT rather than against itself.
final class MDXSpectralTransformTests: XCTestCase {
    /// Small enough to compare against an O(n²) reference, and still a valid
    /// `zrop` length.
    private let nFFT = 64
    private let hop = 16
    /// Enough frames that the middle of the signal is covered by a full set of
    /// overlapping windows, which is where reconstruction is exact.
    private let frames = 32

    // MARK: - Forward

    func testForwardMatchesADirectFourierTransform() throws {
        let bins = nFFT / 2
        let transform = try MDXSpectralTransform(
            nFFT: nFFT,
            hopLength: hop,
            frequencyBins: bins,
            frameCount: frames
        )
        let samplesPerChannel = transform.outputFrames
        let audio = Self.signal(count: 2 * samplesPerChannel)
        var spectrum: [Float] = []

        audio.withUnsafeBufferPointer {
            transform.forward($0.baseAddress!, samplesPerChannel: samplesPerChannel, into: &spectrum)
        }

        XCTAssertEqual(spectrum.count, 4 * bins * frames)
        let window = Self.hannWindow(nFFT)
        for channel in 0..<2 {
            for frame in [0, 1, frames / 2, frames - 1] {
                let start = frame * hop - nFFT / 2
                let windowed = (0..<nFFT).map { sample -> Double in
                    let index = Self.reflected(start + sample, length: samplesPerChannel)
                    return Double(audio[channel * samplesPerChannel + index]) * window[sample]
                }
                let expected = Self.discreteFourierTransform(windowed)
                for bin in [0, 1, 7, bins - 1] {
                    let real = spectrum[Self.index(plane: channel * 2, bin: bin, frame: frame, bins: bins, frames: frames)]
                    let imaginary = spectrum[Self.index(plane: channel * 2 + 1, bin: bin, frame: frame, bins: bins, frames: frames)]
                    XCTAssertEqual(Double(real), expected[bin].real, accuracy: 1e-3)
                    // Bin 0 is real by construction, and the imaginary slot
                    // `zrop` reuses for Nyquist must be cleared.
                    XCTAssertEqual(Double(imaginary), bin == 0 ? 0 : expected[bin].imaginary, accuracy: 1e-3)
                }
            }
        }
    }

    // MARK: - Round trip

    func testRoundTripReconstructsTheSignal() throws {
        let transform = try MDXSpectralTransform(
            nFFT: nFFT,
            hopLength: hop,
            frequencyBins: nFFT / 2,
            frameCount: frames
        )
        let samplesPerChannel = transform.outputFrames
        let audio = Self.signal(count: 2 * samplesPerChannel)
        var spectrum: [Float] = []
        var restored: [Float] = []

        audio.withUnsafeBufferPointer {
            transform.forward($0.baseAddress!, samplesPerChannel: samplesPerChannel, into: &spectrum)
        }
        spectrum.withUnsafeBufferPointer { transform.inverse($0.baseAddress!, into: &restored) }

        XCTAssertEqual(restored.count, audio.count)
        // The edges are reflected rather than real audio, and the separators
        // trim them; compare the interior, which is what gets written.
        for channel in 0..<2 {
            for sample in nFFT..<(samplesPerChannel - nFFT) {
                XCTAssertEqual(
                    restored[channel * samplesPerChannel + sample],
                    audio[channel * samplesPerChannel + sample],
                    accuracy: 1e-3,
                    "channel \(channel), sample \(sample)"
                )
            }
        }
    }

    /// The MDX models emit fewer bins than the transform has, and everything
    /// above them has to stay silent rather than aliasing back in.
    func testBandLimitedSpectrumReconstructsWithoutTheDiscardedBins() throws {
        let bins = nFFT / 4
        let transform = try MDXSpectralTransform(
            nFFT: nFFT,
            hopLength: hop,
            frequencyBins: bins,
            frameCount: frames
        )
        let samplesPerChannel = transform.outputFrames
        let audio = Self.signal(count: 2 * samplesPerChannel)
        var spectrum: [Float] = []
        var restored: [Float] = []

        audio.withUnsafeBufferPointer {
            transform.forward($0.baseAddress!, samplesPerChannel: samplesPerChannel, into: &spectrum)
        }
        spectrum.withUnsafeBufferPointer { transform.inverse($0.baseAddress!, into: &restored) }

        // A low-passed copy is not the original, but it must stay bounded and
        // stay real — an unmirrored inverse would blow up or ring.
        let peak = restored.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertLessThan(peak, 2)
    }

    func testReusingOneInstanceGivesTheSameAnswerEveryTime() throws {
        let transform = try MDXSpectralTransform(
            nFFT: nFFT,
            hopLength: hop,
            frequencyBins: nFFT / 2,
            frameCount: frames
        )
        let samplesPerChannel = transform.outputFrames
        let audio = Self.signal(count: 2 * samplesPerChannel)
        var first: [Float] = []
        var second: [Float] = []
        var firstOutput: [Float] = []
        var secondOutput: [Float] = []

        // Scratch buffers are now allocated once and reused for every chunk of
        // every song, so a stale value from the previous chunk is a real
        // failure mode.
        audio.withUnsafeBufferPointer {
            transform.forward($0.baseAddress!, samplesPerChannel: samplesPerChannel, into: &first)
        }
        first.withUnsafeBufferPointer { transform.inverse($0.baseAddress!, into: &firstOutput) }
        audio.withUnsafeBufferPointer {
            transform.forward($0.baseAddress!, samplesPerChannel: samplesPerChannel, into: &second)
        }
        second.withUnsafeBufferPointer { transform.inverse($0.baseAddress!, into: &secondOutput) }

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstOutput, secondOutput)
    }

    func testAnImpossibleShapeIsRefused() {
        XCTAssertThrowsError(
            try MDXSpectralTransform(
                nFFT: 64,
                hopLength: 16,
                // More bins than a real transform of this length can have.
                frequencyBins: 64,
                frameCount: 32
            )
        )
    }

    // MARK: - Reference implementation

    private static func index(plane: Int, bin: Int, frame: Int, bins: Int, frames: Int) -> Int {
        (plane * bins + bin) * frames + frame
    }

    private static func signal(count: Int) -> [Float] {
        (0..<count).map { index in
            let position = Double(index)
            let low: Double = sin(position * 0.031) * 0.6
            let middle: Double = cos(position * 0.29) * 0.3
            let high: Double = sin(position * 1.13) * 0.1
            return Float(low + middle + high)
        }
    }

    private static func hannWindow(_ length: Int) -> [Double] {
        (0..<length).map { 0.5 * (1 - cos(2 * .pi * Double($0) / Double(length))) }
    }

    private static func discreteFourierTransform(
        _ input: [Double]
    ) -> [(real: Double, imaginary: Double)] {
        let n = input.count
        return (0..<n).map { bin in
            var real = 0.0
            var imaginary = 0.0
            for sample in 0..<n {
                let angle = -2 * Double.pi * Double(sample) * Double(bin) / Double(n)
                real += input[sample] * cos(angle)
                imaginary += input[sample] * sin(angle)
            }
            return (real, imaginary)
        }
    }

    private static func reflected(_ index: Int, length: Int) -> Int {
        var value = index
        while value < 0 || value >= length {
            if value < 0 { value = -value }
            if value >= length { value = 2 * length - value - 2 }
        }
        return value
    }
}
