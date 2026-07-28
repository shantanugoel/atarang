import Accelerate
import AVFoundation

/// Presents a song as a sequence of overlapping non-interleaved stereo windows,
/// reading it through `ResampledAudioStream` rather than holding it.
///
/// All three separators consume audio the same way: a fixed window, a fixed
/// hop, and zeroes outside the song. They differ only in the numbers, and in
/// whether the first window starts before the song does — the MDX models
/// centre their STFT, so their first window begins half a transform early.
///
/// The buffer this exposes is exactly the layout every model wants:
/// `[left(windowFrames), right(windowFrames)]`.
///
/// Synchronization invariant: not thread-safe. One separation run owns an
/// instance and drives it from one task; the conformance exists so it can be
/// handed to that task.
final class PlanarAudioWindowReader: @unchecked Sendable {
    let windowFrames: Int
    let hopFrames: Int
    let format: AVAudioFormat

    /// Source index the window's first sample corresponds to. Negative while
    /// the leading pad is still in view.
    private(set) var windowStart: Int
    /// Real song frames pulled from the file so far. Once `isAtEnd` is true
    /// this is the song's exact length, which is what the callers use to size
    /// the last chunk — no estimate is involved in what gets written.
    private(set) var deliveredFrames = 0

    var isAtEnd: Bool { stream.isAtEnd }
    var estimatedFrameCount: Int { stream.estimatedFrameCount }

    /// `[left, right]`, `windowFrames` each.
    var planar: UnsafeMutablePointer<Float> { storage.baseAddress! }

    private let leadingPadFrames: Int
    private let stream: ResampledAudioStream
    private let storage: UnsafeMutableBufferPointer<Float>
    private var isFirst = true

    init(
        fileURL: URL,
        sampleRate: Double,
        windowFrames: Int,
        hopFrames: Int,
        leadingPadFrames: Int = 0
    ) throws {
        precondition(windowFrames > 0, "a window needs samples in it")
        precondition(
            hopFrames > 0 && hopFrames <= windowFrames,
            "the hop must advance, and cannot skip past the window"
        )
        precondition(
            leadingPadFrames >= 0 && leadingPadFrames < windowFrames,
            "the leading pad must leave room for audio"
        )
        self.windowFrames = windowFrames
        self.hopFrames = hopFrames
        self.leadingPadFrames = leadingPadFrames
        windowStart = -leadingPadFrames
        stream = try ResampledAudioStream(fileURL: fileURL, sampleRate: sampleRate)
        format = stream.format
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: 2 * windowFrames)
        storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    /// Slides to the next window. Returns `false` once no unread audio is left.
    @discardableResult
    func advance() throws -> Bool {
        let base = storage.baseAddress!
        if isFirst {
            isFirst = false
            try fill(from: leadingPadFrames, count: windowFrames - leadingPadFrames)
            return true
        }
        guard !(stream.isAtEnd && windowStart + hopFrames >= deliveredFrames) else {
            return false
        }
        let overlap = windowFrames - hopFrames
        if overlap > 0 {
            for channel in 0..<2 {
                let channelBase = base + channel * windowFrames
                // Overlapping regions, so this has to be a move rather than a copy.
                (channelBase).update(from: channelBase + hopFrames, count: overlap)
            }
        }
        windowStart += hopFrames
        try fill(from: overlap, count: hopFrames)
        return true
    }

    /// Reads `count` frames into both channels at `offset`, zeroing whatever
    /// the song did not reach.
    private func fill(from offset: Int, count: Int) throws {
        let base = storage.baseAddress!
        let produced = try stream.read(
            left: base + offset,
            right: base + windowFrames + offset,
            frames: count
        )
        deliveredFrames += produced
        let unwritten = windowFrames - offset - produced
        if unwritten > 0 {
            for channel in 0..<2 {
                vDSP_vclr(
                    base + channel * windowFrames + offset + produced,
                    1,
                    vDSP_Length(unwritten)
                )
            }
        }
    }
}
