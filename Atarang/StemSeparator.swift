import Accelerate
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
/// Input is streamed from the file and output is streamed to WAV files, so
/// neither the song nor its stems are ever held whole in memory.
///
/// Synchronization invariant: `inferenceLock` serializes the `MLModel`
/// prediction calls that must not overlap, and the scratch buffers are written
/// only by the one detached task that runs a separation.
final class CoreMLWaveformSeparator: @unchecked Sendable {
    private let segmentSamples: Int
    private let overlapSamples: Int
    private let sampleRate = 44_100.0
    private let modelKind: SeparationModelKind
    private let model: MLModel
    private let inferenceLock = NSLock()
    private var input: MLMultiArray?
    private var sourceScratch: [Float] = []
    private var writeBuffer: AVAudioPCMBuffer?

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
        let reader = try PlanarAudioWindowReader(
            fileURL: fileURL,
            sampleRate: sampleRate,
            windowFrames: segmentSamples,
            hopFrames: segmentSamples - overlapSamples
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
        let stride = segmentSamples - overlapSamples
        let format = reader.format
        let estimatedChunks = max(
            1,
            Int(ceil(Double(reader.estimatedFrameCount) / Double(stride)))
        )

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in modelKind.stems {
            let url = outputFolder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            urls[stem] = url
            writers[stem] = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        var previousTails: [StemKind: [Float]] = [:]
        var chunkIndex = 0
        var wroteAnything = false
        while try reader.advance() {
            try Task.checkCancellation()
            let start = chunkIndex * stride
            // Measured, not estimated: the stream reports the song's exact
            // length once it is exhausted, so the last chunk is sized by what
            // the file actually held.
            let validFrames = min(segmentSamples, reader.deliveredFrames - start)
            guard validFrames > 0 else { break }
            let isFirst = chunkIndex == 0
            let isLast = reader.isAtEnd
                && reader.deliveredFrames - start <= segmentSamples

            try autoreleasepool {
                let predictions = try predict(planar: reader.planar)
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
            }
            wroteAnything = true
            chunkIndex += 1
            progress(
                isLast ? 1 : min(0.99, Double(chunkIndex) / Double(estimatedChunks))
            )
            if isLast { break }
        }
        guard wroteAnything else { throw StemSeparatorError.unsupportedFormat }
        return urls
    }

    private func predict(planar: UnsafePointer<Float>) throws -> [StemKind: [Float]] {
        // `[1, 2, samples]` is exactly the reader's own layout, so the chunk
        // goes in as two memcpys rather than an interleave and a de-interleave.
        let audio: MLMultiArray
        if let existing = input {
            audio = existing
        } else {
            audio = try MLMultiArray(
                shape: [1, 2, NSNumber(value: segmentSamples)],
                dataType: .float32
            )
            input = audio
        }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        // Inside the lock, because the array is reused across chunks now:
        // filling it is part of the prediction, not a step before it.
        audio.dataPointer
            .bindMemory(to: Float.self, capacity: audio.count)
            .update(from: planar, count: 2 * segmentSamples)
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
        sourceReader.withValues(in: 0..<expectedValues, scratch: &sourceScratch) { values in
            for (stemIndex, stem) in modelKind.stems.enumerated() {
                let base = stemIndex * 2 * segmentSamples
                var samples = [Float](repeating: 0, count: segmentSamples * 2)
                samples.withUnsafeMutableBufferPointer { destination in
                    interleave(
                        left: values + base,
                        right: values + base + segmentSamples,
                        into: destination.baseAddress!,
                        frames: segmentSamples
                    )
                }
                stems[stem] = samples
            }
        }
        return stems
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
        guard frames > 0 else { return }
        if writeBuffer == nil || Int(writeBuffer!.frameCapacity) < frames {
            writeBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            )
        }
        guard let buffer = writeBuffer, let channels = buffer.floatChannelData else {
            throw StemSeparatorError.unsupportedFormat
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { source in
            deinterleave(
                source.baseAddress!,
                left: channels[0],
                right: channels[1],
                frames: frames
            )
        }
        try file.write(from: buffer)
    }
}

/// Interleaves two planar channels into `left, right, left, right…`.
///
/// `vDSP_ztoc` reads a split complex pair as exactly that layout — the real
/// half becomes the even elements and the imaginary half the odd ones — so the
/// separators' per-sample shuffling loops, millions of iterations per chunk,
/// become one vectorised call.
func interleave(
    left: UnsafePointer<Float>,
    right: UnsafePointer<Float>,
    into destination: UnsafeMutablePointer<Float>,
    frames: Int
) {
    guard frames > 0 else { return }
    var split = DSPSplitComplex(
        realp: UnsafeMutablePointer(mutating: left),
        imagp: UnsafeMutablePointer(mutating: right)
    )
    let pairs = UnsafeMutableRawPointer(destination)
        .assumingMemoryBound(to: DSPComplex.self)
    vDSP_ztoc(&split, 1, pairs, 2, vDSP_Length(frames))
}

/// The reverse of `interleave(left:right:into:frames:)`.
func deinterleave(
    _ source: UnsafePointer<Float>,
    left: UnsafeMutablePointer<Float>,
    right: UnsafeMutablePointer<Float>,
    frames: Int
) {
    guard frames > 0 else { return }
    var split = DSPSplitComplex(realp: left, imagp: right)
    let pairs = UnsafeRawPointer(source)
        .assumingMemoryBound(to: DSPComplex.self)
    vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(frames))
}
