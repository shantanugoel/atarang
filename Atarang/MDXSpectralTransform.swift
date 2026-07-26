import Accelerate
import Foundation

/// Torch-compatible centered STFT layout used by MDX23C and classic MDX-Net ONNX models.
///
/// Synchronization invariant: every stored property is a `let` assigned during
/// `init` and released in `deinit`. The `vDSP_DFT_Setup` handles are not safe
/// for overlapping use, so an instance must be driven by one separation run at
/// a time — which is how `MDXVocalSeparator`, its only owner, uses it.
final class MDXSpectralTransform: @unchecked Sendable {
    let nFFT: Int
    let hopLength: Int
    let frequencyBins: Int
    let frameCount: Int

    private let window: [Float]
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup

    init(nFFT: Int, hopLength: Int, frequencyBins: Int, frameCount: Int = 256) throws {
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.frequencyBins = frequencyBins
        self.frameCount = frameCount
        window = (0..<nFFT).map { index in
            0.5 * (1 - cos(2 * .pi * Float(index) / Float(nFFT)))
        }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else {
            throw StemSeparatorError.inferenceFailed("Accelerate could not create the MDX Fourier transform.")
        }
        self.forward = forward
        self.inverse = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
    }

    /// Input is stereo planar `[left..., right...]`; output is `[1, 4, F, T]` flattened.
    func forward(_ audio: [Float], samplesPerChannel: Int) -> [Float] {
        let centerPadding = nFFT / 2
        var spectrum = [Float](repeating: 0, count: 4 * frequencyBins * frameCount)
        var inputReal = [Float](repeating: 0, count: nFFT)
        var inputImag = [Float](repeating: 0, count: nFFT)
        var outputReal = [Float](repeating: 0, count: nFFT)
        var outputImag = [Float](repeating: 0, count: nFFT)

        for channel in 0..<2 {
            let channelOffset = channel * samplesPerChannel
            for frame in 0..<frameCount {
                let frameStart = frame * hopLength - centerPadding
                for sample in 0..<nFFT {
                    let sourceIndex = reflected(frameStart + sample, length: samplesPerChannel)
                    inputReal[sample] = audio[channelOffset + sourceIndex] * window[sample]
                    inputImag[sample] = 0
                }
                vDSP_DFT_Execute(forward, inputReal, inputImag, &outputReal, &outputImag)
                for frequency in 0..<frequencyBins {
                    spectrum[index(plane: channel * 2, frequency: frequency, frame: frame)] = outputReal[frequency]
                    spectrum[index(plane: channel * 2 + 1, frequency: frequency, frame: frame)] = outputImag[frequency]
                }
            }
        }
        return spectrum
    }

    /// Input is flattened `[1, 4, F, T]`; output is stereo planar with center padding removed.
    func inverse(_ spectrum: [Float]) -> [Float] {
        let paddedLength = (frameCount - 1) * hopLength + nFFT
        let outputLength = paddedLength - nFFT
        let centerPadding = nFFT / 2
        var output = [Float](repeating: 0, count: 2 * paddedLength)
        var normalization = [Float](repeating: 0, count: paddedLength)
        var inputReal = [Float](repeating: 0, count: nFFT)
        var inputImag = [Float](repeating: 0, count: nFFT)
        var frameReal = [Float](repeating: 0, count: nFFT)
        var frameImag = [Float](repeating: 0, count: nFFT)

        for frame in 0..<frameCount {
            let start = frame * hopLength
            for sample in 0..<nFFT {
                let weighted = window[sample]
                normalization[start + sample] += weighted * weighted
            }
        }

        for channel in 0..<2 {
            for frame in 0..<frameCount {
                inputReal.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
                inputImag.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
                for frequency in 0..<frequencyBins {
                    inputReal[frequency] = spectrum[index(plane: channel * 2, frequency: frequency, frame: frame)]
                    inputImag[frequency] = spectrum[index(plane: channel * 2 + 1, frequency: frequency, frame: frame)]
                }
                if frequencyBins > 1 {
                    // Mirror every represented positive-frequency bin except DC
                    // and Nyquist. `frequencyBins` is exclusive, whereas nFFT / 2
                    // is the Nyquist index.
                    let upper = min(frequencyBins, nFFT / 2)
                    if upper > 1 {
                        for frequency in 1..<upper {
                            inputReal[nFFT - frequency] = inputReal[frequency]
                            inputImag[nFFT - frequency] = -inputImag[frequency]
                        }
                    }
                }
                vDSP_DFT_Execute(inverse, inputReal, inputImag, &frameReal, &frameImag)
                let start = frame * hopLength
                for sample in 0..<nFFT {
                    output[channel * paddedLength + start + sample] += frameReal[sample] * window[sample] / Float(nFFT)
                }
            }
        }

        var trimmed = [Float](repeating: 0, count: 2 * outputLength)
        for channel in 0..<2 {
            for sample in 0..<outputLength {
                let paddedIndex = centerPadding + sample
                trimmed[channel * outputLength + sample] = output[channel * paddedLength + paddedIndex]
                    / max(normalization[paddedIndex], 1e-8)
            }
        }
        return trimmed
    }

    private func index(plane: Int, frequency: Int, frame: Int) -> Int {
        (plane * frequencyBins + frequency) * frameCount + frame
    }

    private func reflected(_ index: Int, length: Int) -> Int {
        guard length > 1 else { return 0 }
        var value = index
        while value < 0 || value >= length {
            if value < 0 { value = -value }
            if value >= length { value = 2 * length - value - 2 }
        }
        return value
    }
}
