import AVFoundation

/// Runs the public HTDemucs 6-stem ONNX export in overlapping 7.8-second chunks.
///
/// Synchronization invariant: every stored property is a `let` assigned during
/// `init` and never mutated afterwards, so the instance is only ever read from
/// the detached task that runs the separation.
final class HTDemucs6Separator: @unchecked Sendable {
    private let segmentSamples = 343_980
    private let overlapSamples = 85_995
    private let sampleRate = 44_100.0
    private let session: ONNXModelSession

    init(modelURL: URL) throws {
        // This model requires about 1.1 GB at inference even with FP16-stored
        // weights. Converting its graph to Core ML adds a second large graph
        // during session creation and can make iOS terminate the app. Running
        // it directly in ORT avoids that transient memory spike.
        session = try ONNXModelSession(
            modelURL: modelURL,
            executionBackend: .cpu
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
        let total = Int(mix.frameLength)
        guard total > 0 else { throw StemSeparatorError.unsupportedFormat }
        let stride = segmentSamples - overlapSamples
        let chunkCount = max(1, Int(ceil(Double(max(total - overlapSamples, 1)) / Double(stride))))
        let format = mix.format
        let stems = SeparationModelKind.htdemucs6s.stems

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in stems {
            let url = outputFolder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            urls[stem] = url
            writers[stem] = try AVAudioFile(forWriting: url, settings: format.settings)
        }

        var previousTails: [StemKind: [Float]] = [:]
        for chunkIndex in 0..<chunkCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let start = chunkIndex * stride
                guard start < total else { return }
                let validFrames = min(segmentSamples, total - start)
                let predictions = try predict(chunk: sliceChunk(mix: mix, start: start))
                let isFirst = chunkIndex == 0
                let isLast = chunkIndex == chunkCount - 1

                for stem in stems {
                    guard let samples = predictions[stem], let writer = writers[stem] else { continue }
                    var resolved: [Float]
                    if isFirst && isLast {
                        resolved = Array(samples.prefix(validFrames * 2))
                    } else if isFirst {
                        resolved = Array(samples.prefix(stride * 2))
                        previousTails[stem] = interleavedSlice(samples, frames: stride..<segmentSamples)
                    } else {
                        let overlapCount = min(overlapSamples, validFrames)
                        resolved = blend(
                            previous: previousTails[stem] ?? [],
                            current: samples,
                            frameCount: overlapCount
                        )
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
            progress(Double(chunkIndex + 1) / Double(chunkCount))
        }
        return urls
    }

    private func predict(chunk: [Float]) throws -> [StemKind: [Float]] {
        var planar = [Float](repeating: 0, count: segmentSamples * 2)
        for frame in 0..<segmentSamples {
            planar[frame] = chunk[frame * 2]
            planar[segmentSamples + frame] = chunk[frame * 2 + 1]
        }
        let output = try session.run(
            inputName: "mix",
            outputName: "stems",
            values: planar,
            shape: [1, 2, NSNumber(value: segmentSamples)]
        )
        let sourceOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]
        let required = sourceOrder.count * 2 * segmentSamples
        guard output.count >= required else {
            throw StemSeparatorError.inferenceFailed("HTDemucs 6-stem returned a truncated output.")
        }
        var result: [StemKind: [Float]] = [:]
        for (stemIndex, stem) in sourceOrder.enumerated() {
            let base = stemIndex * 2 * segmentSamples
            var interleaved = [Float](repeating: 0, count: segmentSamples * 2)
            for frame in 0..<segmentSamples {
                interleaved[frame * 2] = output[base + frame]
                interleaved[frame * 2 + 1] = output[base + segmentSamples + frame]
            }
            result[stem] = interleaved
        }
        return result
    }

    private func loadAndResample(fileURL: URL) throws -> AVAudioPCMBuffer {
        try AudioResampler.stereoFloat32(fileURL: fileURL, sampleRate: sampleRate)
    }

    private func sliceChunk(mix: AVAudioPCMBuffer, start: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: segmentSamples * 2)
        guard let channels = mix.floatChannelData else { return samples }
        let frames = min(segmentSamples, Int(mix.frameLength) - start)
        for frame in 0..<frames {
            samples[frame * 2] = channels[0][start + frame]
            samples[frame * 2 + 1] = channels[1][start + frame]
        }
        return samples
    }

    private func blend(previous: [Float], current: [Float], frameCount: Int) -> [Float] {
        var result = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let incoming = Float(frame) / Float(max(frameCount - 1, 1))
            for channel in 0..<2 {
                let index = frame * 2 + channel
                result[index] = (index < previous.count ? previous[index] : 0) * (1 - incoming)
                    + current[index] * incoming
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
