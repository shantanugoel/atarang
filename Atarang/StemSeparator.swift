import AVFoundation
import CoreML

enum StemSeparatorError: LocalizedError {
    case modelNotFound
    case unsupportedFormat
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound: "The bundled HTDemucs model could not be loaded."
        case .unsupportedFormat: "The downloaded audio format could not be converted."
        case .inferenceFailed(let message): "On-device separation failed: \(message)"
        }
    }
}

/// Runs the FP16 HTDemucs Core ML model in overlapping 10-second chunks.
/// Output is streamed to WAV files so a full song's four stems are never held in memory.
final class StemSeparator: @unchecked Sendable {
    private let segmentSamples = 441_000
    private let overlapSamples = 44_100
    private let sampleRate = 44_100.0
    private let model: MLModel
    private let inferenceLock = NSLock()

    init() throws {
        guard let url = Bundle.main.url(forResource: "HTDemucs_CoreML_FP16", withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: "HTDemucs_CoreML_FP16", withExtension: "mlpackage") else {
            throw StemSeparatorError.modelNotFound
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    func separate(
        fileURL: URL,
        outputFolder: URL,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> [StemKind: URL] {
        let mix = try loadAndResample(fileURL: fileURL)
        return try await Task.detached(priority: .userInitiated) {
            try self.runChunked(mix: mix, outputFolder: outputFolder, progress: progress)
        }.value
    }

    private func loadAndResample(fileURL: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: fileURL)
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw StemSeparatorError.unsupportedFormat
        }

        let outputFrames = AVAudioFrameCount(
            ceil(Double(file.length) * sampleRate / file.processingFormat.sampleRate)
        )
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrames),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              ) else { throw StemSeparatorError.unsupportedFormat }
        try file.read(into: input)

        var suppliedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        if let conversionError {
            throw StemSeparatorError.inferenceFailed(conversionError.localizedDescription)
        }
        return output
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
        for stem in StemKind.allCases {
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

            for stem in StemKind.allCases {
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
        let output = sources.dataPointer.bindMemory(to: Float.self, capacity: sources.count)
        var stems: [StemKind: [Float]] = [:]
        for (stemIndex, stem) in StemKind.allCases.enumerated() {
            var samples = [Float](repeating: 0, count: segmentSamples * 2)
            let base = stemIndex * 2 * segmentSamples
            for frame in 0..<segmentSamples {
                samples[frame * 2] = output[base + frame]
                samples[frame * 2 + 1] = output[base + segmentSamples + frame]
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
