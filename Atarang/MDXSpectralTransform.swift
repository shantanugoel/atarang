import Accelerate
import Foundation

/// Torch-compatible centered STFT layout used by MDX23C and classic MDX-Net ONNX models.
///
/// The transform is real-to-complex in both directions. A complex-to-complex
/// DFT on real input does about twice the necessary work, and its inverse needs
/// an explicit conjugate mirror written out bin by bin — `vDSP_DFT_zrop` gets
/// the symmetry for free. Everything else here is vectorised or precomputed for
/// the same reason: this ran 1,536 transforms and roughly 12.6 million scalar
/// loop iterations per chunk, in app code, around an inference that HTDemucs
/// carries inside its own graph.
///
/// `vDSP_DFT_zrop` conventions, which the arithmetic below depends on:
/// the forward transform takes even samples in the real half and odd samples in
/// the imaginary half, and returns **twice** the mathematical transform with the
/// Nyquist bin packed into the imaginary DC slot; the inverse is the mirror of
/// that and returns `nFFT` times the signal. `MDXSpectralTransformTests` pins
/// both against a direct DFT.
///
/// Synchronization invariant: the `vDSP_DFT_Setup` handles and every scratch
/// buffer below are written during `forward` and `inverse`, so an instance must
/// be driven by one separation run at a time — which is how
/// `MDXVocalSeparator`, its only owner, uses it.
final class MDXSpectralTransform: @unchecked Sendable {
    let nFFT: Int
    let hopLength: Int
    let frequencyBins: Int
    let frameCount: Int

    /// Values `forward` expects per channel, and `inverse` produces per channel.
    let outputFrames: Int
    /// Flattened `[1, 4, F, T]` element count.
    var spectrumCount: Int { 4 * frequencyBins * frameCount }

    private let half: Int
    private let paddedLength: Int

    private let window: UnsafeMutableBufferPointer<Float>
    /// `window / nFFT`, so the inverse's overlap-add folds its normalisation
    /// into the multiply it was already doing.
    private let synthesisWindow: UnsafeMutableBufferPointer<Float>
    /// `1 / max(sum of squared windows, 1e-8)` over the trimmed output region,
    /// which depends only on the window and the hop and so is computed once
    /// instead of per inverse.
    private let normalizationReciprocal: UnsafeMutableBufferPointer<Float>

    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    // Scratch, allocated once and reused by every chunk of every song.
    private let frame: UnsafeMutableBufferPointer<Float>
    private let inputReal: UnsafeMutableBufferPointer<Float>
    private let inputImag: UnsafeMutableBufferPointer<Float>
    /// Separate from `inputReal`/`inputImag` because the inverse relies on the
    /// bins at and above `frequencyBins` staying zero for the whole run, and the
    /// forward path's `vDSP_ctoz` writes across all of them.
    private let inverseReal: UnsafeMutableBufferPointer<Float>
    private let inverseImag: UnsafeMutableBufferPointer<Float>
    private let outputReal: UnsafeMutableBufferPointer<Float>
    private let outputImag: UnsafeMutableBufferPointer<Float>
    private let accumulator: UnsafeMutableBufferPointer<Float>

    init(nFFT: Int, hopLength: Int, frequencyBins: Int, frameCount: Int = 256) throws {
        guard nFFT > 0, nFFT % 2 == 0, hopLength > 0, frameCount > 0,
              frequencyBins > 0, frequencyBins <= nFFT / 2 else {
            throw StemSeparatorError.inferenceFailed(
                "The MDX transform was configured with an impossible shape."
            )
        }
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.frequencyBins = frequencyBins
        self.frameCount = frameCount
        half = nFFT / 2
        paddedLength = (frameCount - 1) * hopLength + nFFT
        outputFrames = paddedLength - nFFT

        guard let forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD),
              let inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .INVERSE) else {
            throw StemSeparatorError.inferenceFailed("Accelerate could not create the MDX Fourier transform.")
        }
        self.forwardSetup = forwardSetup
        self.inverseSetup = inverseSetup

        window = Self.allocate(nFFT)
        synthesisWindow = Self.allocate(nFFT)
        for index in 0..<nFFT {
            window[index] = 0.5 * (1 - cos(2 * .pi * Float(index) / Float(nFFT)))
            synthesisWindow[index] = window[index] / Float(nFFT)
        }

        frame = Self.allocate(nFFT)
        inputReal = Self.allocate(half)
        inputImag = Self.allocate(half)
        inverseReal = Self.allocate(half)
        inverseImag = Self.allocate(half)
        outputReal = Self.allocate(half)
        outputImag = Self.allocate(half)
        accumulator = Self.allocate(2 * paddedLength)
        normalizationReciprocal = Self.allocate(max(outputFrames, 1))

        var squared = [Float](repeating: 0, count: nFFT)
        vDSP_vsq(window.baseAddress!, 1, &squared, 1, vDSP_Length(nFFT))
        var normalization = [Float](repeating: 0, count: paddedLength)
        normalization.withUnsafeMutableBufferPointer { total in
            for frameIndex in 0..<frameCount {
                let start = frameIndex * hopLength
                vDSP_vadd(
                    total.baseAddress! + start, 1,
                    squared, 1,
                    total.baseAddress! + start, 1,
                    vDSP_Length(nFFT)
                )
            }
        }
        for index in 0..<outputFrames {
            normalizationReciprocal[index] = 1 / max(normalization[half + index], 1e-8)
        }
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
        for buffer in [
            window, synthesisWindow, normalizationReciprocal, frame,
            inputReal, inputImag, inverseReal, inverseImag,
            outputReal, outputImag, accumulator,
        ] {
            buffer.deallocate()
        }
    }

    /// Input is non-interleaved stereo `[left…, right…]`; output is `[1, 4, F, T]`
    /// flattened into `spectrum`, which is resized only when it is the wrong
    /// size so a run reuses one allocation.
    func forward(
        _ audio: UnsafePointer<Float>,
        samplesPerChannel: Int,
        into spectrum: inout [Float]
    ) {
        if spectrum.count != spectrumCount {
            spectrum = [Float](repeating: 0, count: spectrumCount)
        }
        var scale: Float = 0.5
        spectrum.withUnsafeMutableBufferPointer { output in
            let destination = output.baseAddress!
            for channel in 0..<2 {
                let source = audio + channel * samplesPerChannel
                let realBase = (channel * 2 * frequencyBins) * frameCount
                let imagBase = ((channel * 2 + 1) * frequencyBins) * frameCount
                for frameIndex in 0..<frameCount {
                    let frameStart = frameIndex * hopLength - half
                    if frameStart >= 0, frameStart + nFFT <= samplesPerChannel {
                        // The overwhelming majority of frames sit inside the
                        // chunk, and pay no per-sample reflection at all.
                        vDSP_vmul(
                            source + frameStart, 1,
                            window.baseAddress!, 1,
                            frame.baseAddress!, 1,
                            vDSP_Length(nFFT)
                        )
                    } else {
                        for sample in 0..<nFFT {
                            let index = reflected(frameStart + sample, length: samplesPerChannel)
                            frame[sample] = source[index] * window[sample]
                        }
                    }
                    var split = DSPSplitComplex(
                        realp: inputReal.baseAddress!,
                        imagp: inputImag.baseAddress!
                    )
                    let interleaved = UnsafeRawPointer(frame.baseAddress!)
                        .assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
                    vDSP_DFT_Execute(
                        forwardSetup,
                        inputReal.baseAddress!, inputImag.baseAddress!,
                        outputReal.baseAddress!, outputImag.baseAddress!
                    )
                    // Halve away `zrop`'s factor of two while scattering each
                    // bin into its own plane.
                    vDSP_vsmul(
                        outputReal.baseAddress!, 1,
                        &scale,
                        destination + realBase + frameIndex, frameCount,
                        vDSP_Length(frequencyBins)
                    )
                    vDSP_vsmul(
                        outputImag.baseAddress!, 1,
                        &scale,
                        destination + imagBase + frameIndex, frameCount,
                        vDSP_Length(frequencyBins)
                    )
                    // DC is real; that slot carried the Nyquist bin.
                    destination[imagBase + frameIndex] = 0
                }
            }
        }
    }

    /// Input is flattened `[1, 4, F, T]`; output is non-interleaved stereo with
    /// the centre padding removed, `outputFrames` per channel.
    func inverse(_ spectrum: UnsafePointer<Float>, into output: inout [Float]) {
        if output.count != 2 * outputFrames {
            output = [Float](repeating: 0, count: 2 * outputFrames)
        }
        vDSP_vclr(accumulator.baseAddress!, 1, vDSP_Length(2 * paddedLength))
        var one: Float = 1

        for channel in 0..<2 {
            let realBase = (channel * 2 * frequencyBins) * frameCount
            let imagBase = ((channel * 2 + 1) * frequencyBins) * frameCount
            let channelOutput = accumulator.baseAddress! + channel * paddedLength
            for frameIndex in 0..<frameCount {
                // A strided gather: one frame's bins are `frameCount` apart.
                // Bins at and above `frequencyBins` were zeroed at allocation
                // and are never written, which is exactly the band-limiting the
                // explicit conjugate mirror used to perform by hand.
                vDSP_vsmul(
                    spectrum + realBase + frameIndex, frameCount,
                    &one,
                    inverseReal.baseAddress!, 1,
                    vDSP_Length(frequencyBins)
                )
                vDSP_vsmul(
                    spectrum + imagBase + frameIndex, frameCount,
                    &one,
                    inverseImag.baseAddress!, 1,
                    vDSP_Length(frequencyBins)
                )
                // The imaginary DC slot means Nyquist here, and the models emit
                // nothing there. Dropping the spectrum's imaginary DC matches
                // the old complex transform, whose real part discarded it too.
                inverseImag[0] = 0
                vDSP_DFT_Execute(
                    inverseSetup,
                    inverseReal.baseAddress!, inverseImag.baseAddress!,
                    outputReal.baseAddress!, outputImag.baseAddress!
                )
                var split = DSPSplitComplex(
                    realp: outputReal.baseAddress!,
                    imagp: outputImag.baseAddress!
                )
                let interleaved = UnsafeMutableRawPointer(frame.baseAddress!)
                    .assumingMemoryBound(to: DSPComplex.self)
                vDSP_ztoc(&split, 1, interleaved, 2, vDSP_Length(half))
                let start = frameIndex * hopLength
                vDSP_vma(
                    frame.baseAddress!, 1,
                    synthesisWindow.baseAddress!, 1,
                    channelOutput + start, 1,
                    channelOutput + start, 1,
                    vDSP_Length(nFFT)
                )
            }
        }

        output.withUnsafeMutableBufferPointer { trimmed in
            for channel in 0..<2 {
                vDSP_vmul(
                    accumulator.baseAddress! + channel * paddedLength + half, 1,
                    normalizationReciprocal.baseAddress!, 1,
                    trimmed.baseAddress! + channel * outputFrames, 1,
                    vDSP_Length(outputFrames)
                )
            }
        }
    }

    private static func allocate(_ count: Int) -> UnsafeMutableBufferPointer<Float> {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0)
        return buffer
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
