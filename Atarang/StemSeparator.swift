import AVFoundation
import CoreML

/// Synchronization invariant: `backend` is a `let` assigned during `init` and
/// never mutated afterwards; each backend carries its own invariant.
final class StemSeparator: @unchecked Sendable {
    private enum Backend {
        case waveform(CoreMLWaveformSeparator)
        case htdemucs6s(HTDemucs6Separator)
        case mdx(MDXVocalSeparator)
    }

    private let backend: Backend

    init(modelKind: SeparationModelKind, artifact: SeparationModelArtifact) throws {
        guard modelKind.isAvailableOnCurrentDevice else {
            throw StemSeparatorError.modelUnavailable(modelKind)
        }
        switch (modelKind, artifact) {
        case (.htdemucs, .coreML(let url)):
            backend = .waveform(try CoreMLWaveformSeparator(modelKind: modelKind, modelURL: url))
        case (.htdemucs6s, .onnx(let url)):
            backend = .htdemucs6s(try HTDemucs6Separator(modelURL: url))
        case (.mdx23cInstVocHQ, .coreML(let url)), (.kimVocals, .onnx(let url)):
            backend = .mdx(try MDXVocalSeparator(modelKind: modelKind, modelURL: url))
        default:
            throw StemSeparatorError.incompatibleModel(modelKind, "the installed artifact has the wrong format.")
        }
    }

    func separate(
        fileURL: URL,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [StemKind: URL] {
        switch backend {
        case .waveform(let separator):
            try await separator.separate(fileURL: fileURL, outputFolder: outputFolder, progress: progress)
        case .htdemucs6s(let separator):
            try await separator.separate(fileURL: fileURL, outputFolder: outputFolder, progress: progress)
        case .mdx(let separator):
            try await separator.separate(fileURL: fileURL, outputFolder: outputFolder, progress: progress)
        }
    }
}

enum StemSeparatorError: LocalizedError {
    case modelNotFound(SeparationModelKind)
    case modelUnavailable(SeparationModelKind)
    case incompatibleModel(SeparationModelKind, String)
    case unsupportedFormat
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let model): "The bundled \(model.title) model could not be loaded."
        case .modelUnavailable(let model):
            model.unavailabilityMessage ?? "\(model.title) is not available on this device."
        case .incompatibleModel(let model, let message): "The \(model.title) model is incompatible: \(message)"
        case .unsupportedFormat: "The downloaded audio format could not be converted."
        case .inferenceFailed(let message): "On-device separation failed: \(message)"
        }
    }
}

/// Runs a waveform-to-waveform Core ML separation model in overlapping chunks.
/// Output is streamed to WAV files so a full song's stems are never held in memory.
///
/// Synchronization invariant: every stored property is a `let` assigned during
/// `init` and never mutated afterwards, and `inferenceLock` serializes the
/// `MLModel` prediction calls that must not overlap.
final class CoreMLWaveformSeparator: @unchecked Sendable {
    private let segmentSamples: Int
    private let overlapSamples: Int
    private let sampleRate = 44_100.0
    private let modelKind: SeparationModelKind
    private let model: MLModel
    private let inferenceLock = NSLock()

    init(modelKind: SeparationModelKind, modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        self.modelKind = modelKind

        guard let input = model.modelDescription.inputDescriptionsByName["audio"],
              let shape = input.multiArrayConstraint?.shape,
              let samples = shape.last?.intValue,
              samples > 1 else {
            throw StemSeparatorError.incompatibleModel(
                modelKind,
                "expected an 'audio' multi-array input shaped [1, 2, samples]."
            )
        }
        segmentSamples = samples
        overlapSamples = min(44_100, max(1, samples / 10))
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

    private func loadAndResample(fileURL: URL) throws -> AVAudioPCMBuffer {
        try AudioResampler.stereoFloat32(fileURL: fileURL, sampleRate: sampleRate)
    }

    private func runChunked(
        mix: AVAudioPCMBuffer,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) throws -> [StemKind: URL] {
        let total = Int(mix.frameLength)
        guard total > 0 else { throw StemSeparatorError.unsupportedFormat }
        let stride = segmentSamples - overlapSamples
        let chunkCount = total <= segmentSamples
            ? 1
            : Int(ceil(Double(total - segmentSamples) / Double(stride))) + 1
        let format = mix.format

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in modelKind.stems {
            let url = outputFolder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            urls[stem] = url
            writers[stem] = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        var previousTails: [StemKind: [Float]] = [:]
        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            let start = chunkIndex * stride
            let validFrames = min(segmentSamples, total - start)
            let predictions = try predict(chunk: sliceChunk(mix: mix, start: start))
            let isFirst = chunkIndex == 0
            let isLast = chunkIndex == chunkCount - 1

            for stem in modelKind.stems {
                guard let samples = predictions[stem], let writer = writers[stem] else { continue }
                var resolved: [Float]
                if isFirst && isLast {
                    resolved = Array(samples.prefix(validFrames * 2))
                } else if isFirst {
                    resolved = Array(samples.prefix(stride * 2))
                    previousTails[stem] = interleavedSlice(samples, frames: stride..<segmentSamples)
                } else {
                    let overlapCount = min(overlapSamples, validFrames)
                    let prior = previousTails[stem] ?? []
                    resolved = blend(previous: prior, current: samples, frameCount: overlapCount)
                    let resolvedEnd = isLast ? validFrames : min(stride, validFrames)
                    if resolvedEnd > overlapCount {
                        resolved.append(contentsOf: interleavedSlice(samples, frames: overlapCount..<resolvedEnd))
                    }
                    if !isLast {
                        previousTails[stem] = interleavedSlice(samples, frames: stride..<segmentSamples)
                    }
                }
                try write(interleaved: resolved, to: writer, format: format)
            }
            progress(Double(chunkIndex + 1) / Double(chunkCount))
        }
        return urls
    }

    private func predict(chunk: [Float]) throws -> [StemKind: [Float]] {
        let audio = try MLMultiArray(
            shape: [1, 2, NSNumber(value: segmentSamples)],
            dataType: .float32
        )
        let input = audio.dataPointer.bindMemory(to: Float.self, capacity: audio.count)
        for frame in 0..<segmentSamples {
            input[frame] = chunk[frame * 2]
            input[segmentSamples + frame] = chunk[frame * 2 + 1]
        }

        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": audio])
        let prediction = try model.prediction(from: provider)
        guard let sources = prediction.featureValue(for: "sources")?.multiArrayValue else {
            throw StemSeparatorError.inferenceFailed("The model returned no sources output.")
        }
        var stems: [StemKind: [Float]] = [:]
        let expectedValues = modelKind.stems.count * 2 * segmentSamples
        guard sources.count >= expectedValues else {
            throw StemSeparatorError.incompatibleModel(
                modelKind,
                "expected \(modelKind.stems.count) output stems but received only \(sources.count) values."
            )
        }
        let sourceReader = MLMultiArrayFloatReader(sources)
        for (stemIndex, stem) in modelKind.stems.enumerated() {
            var samples = [Float](repeating: 0, count: segmentSamples * 2)
            let base = stemIndex * 2 * segmentSamples
            for frame in 0..<segmentSamples {
                samples[frame * 2] = sourceReader.value(at: base + frame)
                samples[frame * 2 + 1] = sourceReader.value(
                    at: base + segmentSamples + frame
                )
            }
            stems[stem] = samples
        }
        return stems
    }

    private func sliceChunk(mix: AVAudioPCMBuffer, start: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: segmentSamples * 2)
        guard let channels = mix.floatChannelData else { return samples }
        let total = Int(mix.frameLength)
        for frame in 0..<min(segmentSamples, total - start) {
            samples[frame * 2] = channels[0][start + frame]
            samples[frame * 2 + 1] = channels[1][start + frame]
        }
        return samples
    }

    private func blend(previous: [Float], current: [Float], frameCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let incoming = Float(frame) / Float(max(frameCount - 1, 1))
            let outgoing = 1 - incoming
            for channel in 0..<2 {
                let index = frame * 2 + channel
                let old = index < previous.count ? previous[index] : 0
                result[index] = old * outgoing + current[index] * incoming
            }
        }
        return result
    }

    private func interleavedSlice(_ samples: [Float], frames: Range<Int>) -> [Float] {
        Array(samples[(frames.lowerBound * 2)..<(frames.upperBound * 2)])
    }

    private func write(interleaved samples: [Float], to file: AVAudioFile, format: AVAudioFormat) throws {
        let frames = samples.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { throw StemSeparatorError.unsupportedFormat }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            channels[0][frame] = samples[frame * 2]
            channels[1][frame] = samples[frame * 2 + 1]
        }
        try file.write(from: buffer)
    }
}
