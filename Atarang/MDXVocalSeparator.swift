import AVFoundation
import CoreML

/// Native Swift STFT/iSTFT adapter for MDX23C InstVoc HQ and Kim Vocal 2.
///
/// Synchronization invariant: every stored property is a `let` assigned during
/// `init` and never mutated afterwards, so the instance is only ever read from
/// the detached task that runs the separation.
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
    private let chunkSamples = 261_120
    private let sampleRate = 44_100.0

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
    }

    func separate(
        fileURL: URL,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [StemKind: URL] {
        let mix = try loadAndResample(fileURL: fileURL)
        return try await runCancellable {
            try self.runChunked(mix: mix, outputFolder: outputFolder, progress: progress)
        }
    }

    private func runChunked(
        mix: AVAudioPCMBuffer,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) throws -> [StemKind: URL] {
        guard let channels = mix.floatChannelData else { throw StemSeparatorError.unsupportedFormat }
        let total = Int(mix.frameLength)
        guard total > 0 else { throw StemSeparatorError.unsupportedFormat }
        let trim = configuration.nFFT / 2
        let generatedSamples = chunkSamples - 2 * trim
        let chunkCount = Int(ceil(Double(total) / Double(generatedSamples)))
        let format = mix.format

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in modelKind.stems {
            let url = outputFolder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            urls[stem] = url
            writers[stem] = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let outputStart = chunkIndex * generatedSamples
            let chunk = planarChunk(
                channels: channels,
                total: total,
                sourceStart: outputStart - trim
            )
            var spectrum = transform.forward(chunk, samplesPerChannel: chunkSamples)
            zeroLowFrequencies(&spectrum)
            let predictions = try predict(spectrum: spectrum, mixture: chunk)
            let validFrames = min(generatedSamples, total - outputStart)

            for stem in modelKind.stems {
                guard let planar = predictions[stem], let writer = writers[stem] else { continue }
                try write(
                    planar: planar,
                    range: trim..<(trim + validFrames),
                    samplesPerChannel: chunkSamples,
                    to: writer,
                    format: format
                )
            }
            progress(Double(chunkIndex + 1) / Double(chunkCount))
        }
        return urls
    }

    private func predict(spectrum: [Float], mixture: [Float]) throws -> [StemKind: [Float]] {
        let predictedSpectra: [[Float]]
        switch backend {
        case .coreML(let model):
            let input = try MLMultiArray(
                shape: [1, 4, NSNumber(value: configuration.frequencyBins), 256],
                dataType: .float32
            )
            spectrum.withUnsafeBufferPointer { source in
                input.dataPointer.copyMemory(
                    from: source.baseAddress!,
                    byteCount: source.count * MemoryLayout<Float>.size
                )
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: ["spectrogram": input])
            let result = try model.prediction(from: provider)
            guard let stems = result.featureValue(for: "stems")?.multiArrayValue else {
                throw StemSeparatorError.inferenceFailed("MDX23C returned no stems output.")
            }
            let values = floatValues(from: stems)
            let oneStemCount = 4 * configuration.frequencyBins * 256
            guard values.count >= oneStemCount * 2 else {
                throw StemSeparatorError.inferenceFailed("MDX23C returned a truncated stems output.")
            }
            predictedSpectra = [
                Array(values[0..<oneStemCount]),
                Array(values[oneStemCount..<(oneStemCount * 2)]),
            ]
        case .onnx(let session):
            let shape: [NSNumber] = [1, 4, NSNumber(value: configuration.frequencyBins), 256]
            let positive = try session.runFirst(values: spectrum, shape: shape)
            let negative = try session.runFirst(values: spectrum.map { -$0 }, shape: shape)
            guard positive.count == spectrum.count, negative.count == spectrum.count else {
                throw StemSeparatorError.inferenceFailed("Kim Vocals returned an unexpected spectrum shape.")
            }
            predictedSpectra = [zip(positive, negative).map { ($0 - $1) * 0.5 }]
        }

        var vocals = transform.inverse(predictedSpectra[0])
        if configuration.compensation != 1 {
            for index in vocals.indices { vocals[index] *= configuration.compensation }
        }
        let instrumental: [Float]
        if configuration.returnsInstrumental {
            instrumental = transform.inverse(predictedSpectra[1])
        } else {
            instrumental = zip(mixture, vocals).map { $0 - $1 }
        }
        return [.vocals: vocals, .instrumental: instrumental]
    }

    private func zeroLowFrequencies(_ spectrum: inout [Float]) {
        let frames = 256
        for plane in 0..<4 {
            for frequency in 0..<3 {
                let start = (plane * configuration.frequencyBins + frequency) * frames
                spectrum.replaceSubrange(start..<(start + frames), with: repeatElement(0, count: frames))
            }
        }
    }

    private func planarChunk(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        total: Int,
        sourceStart: Int
    ) -> [Float] {
        var result = [Float](repeating: 0, count: 2 * chunkSamples)
        for channel in 0..<2 {
            for sample in 0..<chunkSamples {
                let source = sourceStart + sample
                if source >= 0, source < total {
                    result[channel * chunkSamples + sample] = channels[channel][source]
                }
            }
        }
        return result
    }

    private func loadAndResample(fileURL: URL) throws -> AVAudioPCMBuffer {
        try AudioResampler.stereoFloat32(fileURL: fileURL, sampleRate: sampleRate)
    }

    private func floatValues(from array: MLMultiArray) -> [Float] {
        MLMultiArrayFloatReader(array).values()
    }

    private func write(
        planar: [Float],
        range: Range<Int>,
        samplesPerChannel: Int,
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        let frameCount = range.count
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channels = buffer.floatChannelData else { throw StemSeparatorError.unsupportedFormat }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for frame in 0..<frameCount {
            channels[0][frame] = planar[range.lowerBound + frame]
            channels[1][frame] = planar[samplesPerChannel + range.lowerBound + frame]
        }
        try file.write(from: buffer)
    }
}
