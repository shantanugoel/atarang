import AVFoundation

/// Loads an audio file as non-interleaved stereo float at `sampleRate`,
/// resampling when the file's own rate differs.
///
/// Every separator backend needs the mix in exactly this layout, so the
/// conversion lives here rather than being repeated per model.
enum AudioResampler {
    /// How much audio one conversion pass moves. Large enough that the
    /// converter callback is not the cost, small enough to be noise beside a
    /// separation's own working set.
    static let blockFrames: AVAudioFrameCount = 32_768

    /// The whole file as one buffer.
    ///
    /// Reads through `ResampledAudioStream`, so the undecoded file is no longer
    /// held in memory beside the converted result — that used to double the
    /// peak for the length of the conversion. The result is still one
    /// song-sized allocation, which is why the separators read the stream
    /// directly instead of calling this.
    static func stereoFloat32(
        fileURL: URL,
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        let stream = try ResampledAudioStream(fileURL: fileURL, sampleRate: sampleRate)
        let capacity = max(stream.estimatedFrameCount, 1)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: stream.format,
            frameCapacity: AVAudioFrameCount(capacity)
        ), let channels = output.floatChannelData else {
            throw StemSeparatorError.unsupportedFormat
        }
        var produced = 0
        while produced < capacity {
            let read = try stream.read(
                left: channels[0] + produced,
                right: channels[1] + produced,
                frames: capacity - produced
            )
            if read == 0 { break }
            produced += read
        }
        output.frameLength = AVAudioFrameCount(produced)
        return output
    }
}

/// Sequential non-interleaved stereo reader that resamples as it goes.
///
/// Separation used to begin by materialising the whole song — about 85 MB of
/// float samples for four minutes, held for the entire run — and the
/// conversion that produced it held the decoded source beside it. This reads
/// the file a block at a time instead, so the mix stops being part of the
/// steady-state footprint.
///
/// Synchronization invariant: not thread-safe. One separation run owns an
/// instance and reads it from one task; the `@unchecked Sendable` conformance
/// exists so it can be handed to that task, not so two can share it.
final class ResampledAudioStream: @unchecked Sendable {
    let format: AVAudioFormat
    /// What the file's length implies the converted output will be. Exact for
    /// same-rate files and within a frame or two after resampling, so it is
    /// used for progress and capacity, never for correctness.
    let estimatedFrameCount: Int
    private(set) var isAtEnd = false

    private let converter: AVAudioConverter
    private let source: StreamingConverterInput
    private let block: AVAudioPCMBuffer
    private var blockOffset = 0

    init(fileURL: URL, sampleRate: Double) throws {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: target),
           let block = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: AudioResampler.blockFrames
           ) else { throw StemSeparatorError.unsupportedFormat }
        format = target
        self.converter = converter
        self.block = block
        estimatedFrameCount = sourceFormat.sampleRate > 0
            ? Int(ceil(Double(file.length) * sampleRate / sourceFormat.sampleRate))
            : 0
        source = try StreamingConverterInput(
            file: file,
            frames: AudioResampler.blockFrames
        )
    }

    /// Fills up to `frames` samples per channel and returns how many it wrote.
    /// A short result means the file ended.
    @discardableResult
    func read(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frames: Int
    ) throws -> Int {
        var written = 0
        while written < frames {
            if blockOffset >= Int(block.frameLength) {
                guard try refill() else { break }
            }
            guard let channels = block.floatChannelData else { break }
            let take = min(Int(block.frameLength) - blockOffset, frames - written)
            guard take > 0 else { break }
            (left + written).update(from: channels[0] + blockOffset, count: take)
            (right + written).update(from: channels[1] + blockOffset, count: take)
            blockOffset += take
            written += take
        }
        return written
    }

    private func refill() throws -> Bool {
        guard !isAtEnd else { return false }
        blockOffset = 0
        block.frameLength = 0
        var conversionError: NSError?
        // The block is `@Sendable`, so it captures the input supplier rather
        // than `self`.
        let supplier = source
        let status = converter.convert(to: block, error: &conversionError) { _, status in
            supplier.supply(status)
        }
        if let failure = supplier.thrownError {
            throw failure
        }
        // Only `.error` is a failure. The converter also reports an error
        // object alongside `.endOfStream`, which is just how it says the file
        // ran out — treating that as a throw ended every conversion in a
        // spurious failure.
        if status == .error {
            throw StemSeparatorError.inferenceFailed(
                conversionError?.localizedDescription
                    ?? "The audio could not be converted."
            )
        }
        if status == .endOfStream || block.frameLength == 0 {
            isAtEnd = true
        }
        return block.frameLength > 0
    }
}

/// Feeds an `AVAudioConverter` from a file, one block at a time.
///
/// `AVAudioConverterInputBlock` is `@Sendable`, so it cannot capture and mutate
/// a local flag even though the converter invokes it synchronously.
///
/// Synchronization invariant: every access to the file, the buffer ring, and
/// the failure state happens under `lock`.
private final class StreamingConverterInput: @unchecked Sendable {
    private let file: AVAudioFile
    /// A ring rather than one buffer: the converter is documented to consume
    /// the buffer it is handed, but it may still be reading the previous one
    /// when it asks for the next, and overwriting that would corrupt the
    /// resampler's history silently.
    private let buffers: [AVAudioPCMBuffer]
    private let lock = NSLock()
    private var nextBuffer = 0
    private var isFinished = false
    private var failure: Error?

    init(file: AVAudioFile, frames: AVAudioFrameCount) throws {
        self.file = file
        buffers = try (0..<3).map { _ in
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frames
            ) else { throw StemSeparatorError.unsupportedFormat }
            return buffer
        }
    }

    func supply(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        // `AVAudioFile.read(into:)` does not report a clean end of file: asked
        // for frames past the last one it fails without setting an error, which
        // surfaces as an opaque `nilError`. The position is the reliable signal.
        guard !isFinished, file.framePosition < file.length else {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        let buffer = buffers[nextBuffer]
        nextBuffer = (nextBuffer + 1) % buffers.count
        do {
            try file.read(into: buffer)
        } catch {
            failure = error
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        guard buffer.frameLength > 0 else {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }

    var thrownError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}
