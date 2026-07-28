import Accelerate
import AVFoundation

/// Runs the public HTDemucs 6-stem ONNX export in overlapping 7.8-second chunks.
///
/// Synchronization invariant: the scratch buffer below is written only by the
/// one detached task that runs a separation, and everything else is a `let`
/// assigned during `init`.
final class HTDemucs6Separator: @unchecked Sendable {
    private let segmentSamples = 343_980
    private let overlapSamples = 85_995
    private let sampleRate = 44_100.0
    private let session: ONNXModelSession
    private var writeBuffer: AVAudioPCMBuffer?

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
        let stems = SeparationModelKind.htdemucs6s.stems
        let estimatedChunks = max(
            1,
            Int(ceil(Double(reader.estimatedFrameCount) / Double(stride)))
        )

        var urls: [StemKind: URL] = [:]
        var writers: [StemKind: AVAudioFile] = [:]
        for stem in stems {
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
            // Measured, not estimated: once the stream is exhausted
            // `deliveredFrames` is the song's exact length.
            let validFrames = min(segmentSamples, reader.deliveredFrames - start)
            guard validFrames > 0 else { break }
            let isFirst = chunkIndex == 0
            let isLast = reader.isAtEnd
                && reader.deliveredFrames - start <= segmentSamples

            try autoreleasepool {
                let predictions = try predict(planar: reader.planar)
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
        let sourceOrder: [StemKind] = [.drums, .bass, .other, .vocals, .guitar, .piano]
        let required = sourceOrder.count * 2 * segmentSamples
        // The reader already hands over `[left…, right…]`, which is the shape
        // the model wants, so the chunk goes straight in.
        return try session.run(
            inputName: "mix",
            outputName: "stems",
            values: UnsafeBufferPointer(start: planar, count: segmentSamples * 2),
            shape: [1, 2, NSNumber(value: segmentSamples)]
        ) { output in
            guard output.count >= required else {
                throw StemSeparatorError.inferenceFailed("HTDemucs 6-stem returned a truncated output.")
            }
            var result: [StemKind: [Float]] = [:]
            for (stemIndex, stem) in sourceOrder.enumerated() {
                let base = stemIndex * 2 * segmentSamples
                var interleaved = [Float](repeating: 0, count: segmentSamples * 2)
                interleaved.withUnsafeMutableBufferPointer { destination in
                    interleave(
                        left: output.baseAddress! + base,
                        right: output.baseAddress! + base + segmentSamples,
                        into: destination.baseAddress!,
                        frames: segmentSamples
                    )
                }
                result[stem] = interleaved
            }
            return result
        }
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
