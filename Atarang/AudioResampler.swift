import AVFoundation

/// Loads an audio file into a single non-interleaved stereo float buffer at
/// `sampleRate`, resampling when the file's own rate differs.
///
/// Every separator backend needs the mix in exactly this layout, so the
/// conversion lives here rather than being repeated per model.
enum AudioResampler {
    static func stereoFloat32(
        fileURL: URL,
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
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

        let source = SingleBufferConverterInput(input)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { source.supply($1) }
        if let conversionError {
            throw StemSeparatorError.inferenceFailed(conversionError.localizedDescription)
        }
        return output
    }
}

/// Hands one already-read buffer to an `AVAudioConverter`, then reports end of
/// stream.
///
/// `AVAudioConverterInputBlock` is `@Sendable`, so it cannot capture and mutate
/// a local flag, even though `convert(to:error:withInputFrom:)` invokes it
/// synchronously on the calling thread before returning.
///
/// Synchronization invariant: `buffer` is fully written by the caller before
/// this object is created and is only read afterwards. `isDelivered` is the
/// only mutable state and every access to it is serialized by `lock`.
private final class SingleBufferConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var isDelivered = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func supply(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if isDelivered {
            status.pointee = .endOfStream
            return nil
        }
        isDelivered = true
        status.pointee = .haveData
        return buffer
    }
}
