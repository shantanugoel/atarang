import Accelerate
import AVFoundation
import CoreML

/// Native Swift STFT/iSTFT adapter for MDX23C InstVoc HQ and Kim Vocal 2.
///
/// Unlike HTDemucs, these models do not carry their spectral transform inside
/// the graph, so the app performs it — 1,536 transforms per chunk plus the
/// windowing, mirroring, and overlap-add around them. That work, not the
/// models, is why a vocal separation used to take longer than the balanced
/// 4-stem split. `MDXSpectralTransform` holds the fast implementation; this
/// file's job is to keep the buffers around it from being reallocated, copied,
/// or held longer than one chunk needs them.
///
/// Synchronization invariant: the scratch buffers below are written while a
/// separation runs, so an instance must be driven by one run at a time. That is
/// how `StemSeparator`, its only owner, uses it: one instance per separation,
/// handed to one detached task.
final class MDXVocalSeparator: @unchecked Sendable {
    private enum Backend {
        case coreML(MLModel)
        case onnx(ONNXModelSession)
    }

    private struct Configuration {
        let nFFT: Int
        let frequencyBins: Int
        let compensation: Float
        let returnsInstrumental: Bool
    }

    private let modelKind: SeparationModelKind
    private let backend: Backend
    private let configuration: Configuration
    private let transform: MDXSpectralTransform
    private let chunkSamples: Int
    private let sampleRate = 44_100.0

    // Reused by every chunk rather than reallocated per call. The spectrum
    // alone is 16.8 MB for MDX23C, and there used to be four of them alive at
    // once on the Kim Vocals path.
    private var spectrum: [Float] = []
    private var predicted: [Float] = []
    private var vocals: [Float] = []
    private var instrumental: [Float] = []
    private var readerScratch: [Float] = []
    private var writeBuffer: AVAudioPCMBuffer?

    init(modelKind: SeparationModelKind, modelURL: URL) throws {
        self.modelKind = modelKind
        switch modelKind {
        case .mdx23cInstVocHQ:
            let mlConfiguration = MLModelConfiguration()
            mlConfiguration.computeUnits = .cpuAndGPU
            backend = .coreML(try MLModel(contentsOf: modelURL, configuration: mlConfiguration))
            configuration = Configuration(
                nFFT: 8_192,
                frequencyBins: 4_096,
                compensation: 1,
                returnsInstrumental: true
            )
        case .kimVocals:
            backend = .onnx(try ONNXModelSession(modelURL: modelURL))
            configuration = Configuration(
                nFFT: 7_680,
                frequencyBins: 3_072,
                compensation: 1.009,
                returnsInstrumental: false
            )
        default:
            throw StemSeparatorError.incompatibleModel(modelKind, "expected an MDX vocal model.")
        }
        transform = try MDXSpectralTransform(
            nFFT: configuration.nFFT,
            hopLength: 1_024,
            frequencyBins: configuration.frequencyBins
        )
        // Derived rather than stated, so the chunk and the transform cannot
        // disagree about how much audio one inference covers.
        chunkSamples = transform.outputFrames
    }

    func separate(
        fileURL: URL,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [StemKind: URL] {
        let trim = configuration.nFFT / 2
        let reader = try PlanarAudioWindowReader(
            fileURL: fileURL,
            sampleRate: sampleRate,
            windowFrames: chunkSamples,
            hopFrames: chunkSamples - 2 * trim,
            leadingPadFrames: trim
        )
        return try await runCancellable {
            try self.runChunked(
                reader: reader,
                outputFolder: outputFolder,
                progress: progress
            )
        }
    }

    private func runChunked(
        reader: PlanarAudioWindowReader,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) throws -> [StemKind: URL] {
        let trim = configuration.nFFT / 2
        let generatedSamples = chunkSamples - 2 * trim
        let format = reader.format
        let estimatedChunks = max(
            1,
            Int(ceil(Double(reader.estimatedFrameCount) / Double(generatedSamples)))
        )

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in modelKind.stems {
            let url = outputFolder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            urls[stem] = url
            writers[stem] = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        var chunkIndex = 0
        var wroteAnything = false
        while try reader.advance() {
            try Task.checkCancellation()
            let outputStart = chunkIndex * generatedSamples
            // `deliveredFrames` is measured, not estimated: once the stream is
            // exhausted it is the song's exact length, so the last chunk writes
            // exactly as much audio as the song has.
            let validFrames = min(generatedSamples, reader.deliveredFrames - outputStart)
            guard validFrames > 0 else { break }

            try autoreleasepool {
                transform.forward(
                    reader.planar,
                    samplesPerChannel: chunkSamples,
                    into: &spectrum
                )
                zeroLowFrequencies()
                try predict(mixture: reader.planar)

                for stem in modelKind.stems {
                    guard let writer = writers[stem] else { continue }
                    let planar = stem == .vocals ? vocals : instrumental
                    try write(
                        planar: planar,
                        range: trim..<(trim + validFrames),
                        to: writer,
                        format: format
                    )
                }
            }

            wroteAnything = true
            chunkIndex += 1
            let isFinal = reader.isAtEnd
                && reader.deliveredFrames - outputStart <= generatedSamples
            progress(
                isFinal ? 1 : min(0.99, Double(chunkIndex) / Double(estimatedChunks))
            )
            if isFinal { break }
        }
        // A song with no audio in it is not a separation with empty stems.
        guard wroteAnything else { throw StemSeparatorError.unsupportedFormat }
        return urls
    }

    /// Fills `vocals` and `instrumental` for the current chunk.
    private func predict(mixture: UnsafePointer<Float>) throws {
        switch backend {
        case .coreML(let model):
            try predictWithCoreML(model)
        case .onnx(let session):
            try predictWithONNX(session)
        }

        if configuration.compensation != 1 {
            var factor = configuration.compensation
            vocals.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsmul(
                    buffer.baseAddress!, 1,
                    &factor,
                    buffer.baseAddress!, 1,
                    vDSP_Length(buffer.count)
                )
            }
        }
        if !configuration.returnsInstrumental {
            // Whatever the model did not call vocal is the backing track.
            if instrumental.count != vocals.count {
                instrumental = [Float](repeating: 0, count: vocals.count)
            }
            let count = vDSP_Length(vocals.count)
            vocals.withUnsafeBufferPointer { sung in
                instrumental.withUnsafeMutableBufferPointer { rest in
                    vDSP_vsub(
                        sung.baseAddress!, 1,
                        mixture, 1,
                        rest.baseAddress!, 1,
                        count
                    )
                }
            }
        }
    }

    private func predictWithCoreML(_ model: MLModel) throws {
        let oneStemCount = transform.spectrumCount
        // The input array points straight at the spectrum buffer instead of
        // copying 16.8 MB into a fresh `MLMultiArray` for every chunk.
        let result: MLFeatureProvider = try spectrum.withUnsafeMutableBufferPointer { source in
            let input = try MLMultiArray(
                dataPointer: UnsafeMutableRawPointer(source.baseAddress!),
                shape: [1, 4, NSNumber(value: configuration.frequencyBins), 256],
                dataType: .float32,
                strides: [
                    NSNumber(value: oneStemCount),
                    NSNumber(value: configuration.frequencyBins * 256),
                    256,
                    1,
                ],
                deallocator: nil
            )
            let provider = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": input])
            return try model.prediction(from: provider)
        }
        guard let stems = result.featureValue(for: "stems")?.multiArrayValue else {
            throw StemSeparatorError.inferenceFailed("MDX23C returned no stems output.")
        }
        let reader = MLMultiArrayFloatReader(stems)
        guard reader.count >= oneStemCount * 2 else {
            throw StemSeparatorError.inferenceFailed("MDX23C returned a truncated stems output.")
        }
        // Two inverse transforms straight off the model's own output. This used
        // to materialise the whole 33.5 MB result and then copy each half out
        // of it again.
        reader.withValues(in: 0..<oneStemCount, scratch: &readerScratch) { values in
            transform.inverse(values, into: &vocals)
        }
        reader.withValues(in: oneStemCount..<(oneStemCount * 2), scratch: &readerScratch) { values in
            transform.inverse(values, into: &instrumental)
        }
    }

    private func predictWithONNX(_ session: ONNXModelSession) throws {
        let shape: [NSNumber] = [
            1, 4, NSNumber(value: configuration.frequencyBins), 256,
        ]
        let count = spectrum.count
        if predicted.count != count {
            predicted = [Float](repeating: 0, count: count)
        }
        // Kim Vocals is averaged with its own negated input, which is two
        // inferences per chunk. They are accumulated in one buffer rather than
        // held as two full spectra plus a zipped third.
        try spectrum.withUnsafeBufferPointer { input in
            try session.runFirst(values: input, shape: shape) { output in
                guard output.count == count else {
                    throw StemSeparatorError.inferenceFailed(
                        "Kim Vocals returned an unexpected spectrum shape."
                    )
                }
                predicted.withUnsafeMutableBufferPointer { accumulator in
                    accumulator.baseAddress!.update(
                        from: output.baseAddress!,
                        count: count
                    )
                }
            }
        }
        spectrum.withUnsafeMutableBufferPointer { buffer in
            vDSP_vneg(buffer.baseAddress!, 1, buffer.baseAddress!, 1, vDSP_Length(count))
        }
        try spectrum.withUnsafeBufferPointer { input in
            try session.runFirst(values: input, shape: shape) { output in
                guard output.count == count else {
                    throw StemSeparatorError.inferenceFailed(
                        "Kim Vocals returned an unexpected spectrum shape."
                    )
                }
                var scale: Float = 0.5
                predicted.withUnsafeMutableBufferPointer { accumulator in
                    // (positive - negative) * 0.5
                    vDSP_vsub(
                        output.baseAddress!, 1,
                        accumulator.baseAddress!, 1,
                        accumulator.baseAddress!, 1,
                        vDSP_Length(count)
                    )
                    vDSP_vsmul(
                        accumulator.baseAddress!, 1,
                        &scale,
                        accumulator.baseAddress!, 1,
                        vDSP_Length(count)
                    )
                }
            }
        }
        predicted.withUnsafeBufferPointer { values in
            transform.inverse(values.baseAddress!, into: &vocals)
        }
    }

    /// The models are trained with the lowest bins muted, and leaving them in
    /// puts rumble into both stems.
    private func zeroLowFrequencies() {
        let frames = transform.frameCount
        spectrum.withUnsafeMutableBufferPointer { buffer in
            for plane in 0..<4 {
                let start = (plane * configuration.frequencyBins) * frames
                vDSP_vclr(buffer.baseAddress! + start, 1, vDSP_Length(frames * 3))
            }
        }
    }

    private func write(
        planar: [Float],
        range: Range<Int>,
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let frameCount = range.count
        guard frameCount > 0 else { return }
        if writeBuffer == nil || Int(writeBuffer!.frameCapacity) < frameCount {
            writeBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            )
        }
        guard let buffer = writeBuffer, let channels = buffer.floatChannelData else {
            throw StemSeparatorError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        planar.withUnsafeBufferPointer { source in
            channels[0].update(
                from: source.baseAddress! + range.lowerBound,
                count: frameCount
            )
            channels[1].update(
                from: source.baseAddress! + chunkSamples + range.lowerBound,
                count: frameCount
            )
        }
        try file.write(from: buffer)
    }
}
