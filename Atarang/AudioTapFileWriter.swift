import AVFoundation
import Foundation

/// Writes buffers delivered by an audio tap to a file, off the render thread,
/// and remembers the first failure instead of losing it.
///
/// Two things this type exists to prevent:
///
/// - **A failed write disappearing.** The tap callbacks used to `print()` and
///   carry on, so a full disk produced a take that looked fine and contained
///   silence. The first error is captured, reported once through `onFailure`,
///   and returned from `finish()` so the caller can refuse to commit.
/// - **File I/O running on the audio thread.** Buffers are copied and handed to
///   a serial queue. The queue is bounded: if writing cannot keep up, the take
///   fails loudly rather than dropping audio quietly.
///
/// Synchronization invariant: `url` is immutable; every other stored property is
/// read and written only while `lock` is held, except `file`, which is touched
/// exclusively on `queue`. The render thread therefore only ever takes the lock
/// briefly to enqueue.
final class AudioTapFileWriter: @unchecked Sendable {
    enum WriterError: LocalizedError, Equatable {
        case backlog
        case couldNotCopyBuffer

        var errorDescription: String? {
            switch self {
            case .backlog:
                "Audio could not be written to storage fast enough."
            case .couldNotCopyBuffer:
                "A recorded audio buffer could not be captured."
            }
        }
    }

    /// ~6 seconds of 4096-frame buffers at 44.1 kHz. Deep enough that a
    /// momentary storage stall is absorbed, shallow enough that a genuinely
    /// stuck writer is caught while the take is still short.
    private static let maximumPendingBuffers = 64

    private let url: URL
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var pendingBuffers = 0
    private var failure: Error?
    /// Closed to *new* buffers. Anything already queued is still written —
    /// dropping it would silently lose the end of every take.
    private var isAcceptingWrites = true
    private var failureHandler: (@Sendable (Error) -> Void)?

    /// Opens the destination lazily, using the format of the first buffer the
    /// running graph actually delivers rather than a possibly stale pre-start
    /// format.
    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "com.shantanugoel.atarang.tapwriter", qos: .userInitiated)
    }

    /// Creates the destination immediately, for callers that already know the
    /// format and want a failure surfaced before the take starts rather than
    /// from inside a render callback.
    convenience init(
        url: URL,
        settings: [String: Any],
        commonFormat: AVAudioCommonFormat,
        interleaved: Bool
    ) throws {
        self.init(url: url)
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: commonFormat,
            interleaved: interleaved
        )
    }

    /// Called once, on the first failure, from the writer queue.
    func setFailureHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        lock.lock()
        failureHandler = handler
        let existing = failure
        lock.unlock()
        if let existing { handler(existing) }
    }

    var currentFailure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    /// Enqueues a buffer. Safe to call from a render thread: it copies and
    /// returns, and never touches the filesystem inline.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if !isAcceptingWrites || failure != nil {
            lock.unlock()
            return
        }
        guard pendingBuffers < Self.maximumPendingBuffers else {
            lock.unlock()
            recordFailure(WriterError.backlog)
            return
        }
        pendingBuffers += 1
        lock.unlock()

        guard let copy = Self.copy(buffer) else {
            lock.lock()
            pendingBuffers -= 1
            lock.unlock()
            recordFailure(WriterError.couldNotCopyBuffer)
            return
        }

        let handoff = BufferHandoff(buffer: copy)
        queue.async { [weak self] in
            guard let self else { return }
            let copy = handoff.buffer
            defer {
                self.lock.lock()
                self.pendingBuffers -= 1
                self.lock.unlock()
            }
            // Only a failure stops the drain: once a buffer is queued it is
            // part of the take, including the ones enqueued just before
            // `finish()`.
            guard self.currentFailure == nil else { return }
            do {
                if self.file == nil {
                    self.file = try AVAudioFile(
                        forWriting: self.url,
                        settings: copy.format.settings,
                        commonFormat: copy.format.commonFormat,
                        interleaved: copy.format.isInterleaved
                    )
                }
                try self.file?.write(from: copy)
            } catch {
                self.recordFailure(error)
            }
        }
    }

    /// Drains anything still queued, closes the file, and reports the first
    /// failure seen during the take, if any.
    @discardableResult
    func finish() -> Error? {
        lock.lock()
        isAcceptingWrites = false
        lock.unlock()
        // `sync` on the serial queue runs after everything already enqueued, so
        // this both drains the backlog and closes the file.
        queue.sync { file = nil }
        return currentFailure
    }

    private func recordFailure(_ error: Error) {
        lock.lock()
        guard failure == nil else {
            lock.unlock()
            return
        }
        failure = error
        let handler = failureHandler
        lock.unlock()
        handler?(error)
    }

    /// Carries one freshly copied buffer from the tap thread to the writer
    /// queue.
    ///
    /// Synchronization invariant: the buffer is created inside `write(_:)` and
    /// handed off immediately; the producer keeps no reference and never reads
    /// or writes it again, so exactly one thread can see it at a time. This is
    /// an ownership transfer, which `AVAudioPCMBuffer` has no way to express.
    private struct BufferHandoff: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// A deep copy through the buffer list, so it works for any PCM layout the
    /// tap hands us rather than only deinterleaved float.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: buffer.frameLength
              ) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData,
                  let to = destination[index].mData else { return nil }
            let bytes = min(
                Int(source[index].mDataByteSize),
                Int(destination[index].mDataByteSize)
            )
            memcpy(to, from, bytes)
            destination[index].mDataByteSize = UInt32(bytes)
        }
        return copy
    }
}
