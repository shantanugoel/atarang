import Foundation

struct PlaybackLoopRange: Codable, Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.5

    let start: TimeInterval
    let end: TimeInterval

    init?(start: TimeInterval, end: TimeInterval, duration: TimeInterval) {
        guard start.isFinite, end.isFinite, duration.isFinite, duration > 0 else {
            return nil
        }
        let clampedStart = min(max(0, start), duration)
        let clampedEnd = min(max(0, end), duration)
        guard clampedEnd - clampedStart >= Self.minimumDuration else { return nil }
        self.start = clampedStart
        self.end = clampedEnd
    }

    var duration: TimeInterval { end - start }
}

/// The media-time state shared by playback, looping, transforms, and recording.
///
/// `position` is always expressed in source-song seconds. Render time is
/// converted to media time with `rate`, keeping UI and recording boundaries
/// correct when playback is transformed.
struct PlaybackState: Equatable, Sendable {
    static let supportedRateRange: ClosedRange<Float> = 0.5...1.0
    static let supportedPitchRange: ClosedRange<Float> = -12...12

    private(set) var position: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1
    private(set) var pitchSemitones: Float = 0
    private(set) var loopRange: PlaybackLoopRange?
    private(set) var playbackGeneration = 0

    mutating func load(duration: TimeInterval) {
        self.duration = Self.validDuration(duration)
        position = 0
        rate = 1
        pitchSemitones = 0
        loopRange = nil
        playbackGeneration &+= 1
    }

    mutating func unload() {
        position = 0
        duration = 0
        rate = 1
        pitchSemitones = 0
        loopRange = nil
        playbackGeneration &+= 1
    }

    mutating func seek(to value: TimeInterval) {
        guard value.isFinite else { return }
        position = min(max(0, value), duration)
    }

    mutating func setRate(_ value: Float) {
        guard value.isFinite else { return }
        rate = min(max(value, Self.supportedRateRange.lowerBound), Self.supportedRateRange.upperBound)
    }

    mutating func setPitchSemitones(_ value: Float) {
        guard value.isFinite else { return }
        pitchSemitones = min(
            max(value, Self.supportedPitchRange.lowerBound),
            Self.supportedPitchRange.upperBound
        )
    }

    @discardableResult
    mutating func setLoop(start: TimeInterval, end: TimeInterval) -> Bool {
        guard let range = PlaybackLoopRange(start: start, end: end, duration: duration) else {
            return false
        }
        loopRange = range
        if position < range.start || position >= range.end {
            position = range.start
        }
        playbackGeneration &+= 1
        return true
    }

    mutating func clearLoop() {
        loopRange = nil
        playbackGeneration &+= 1
    }

    @discardableResult
    mutating func beginNewGeneration() -> Int {
        playbackGeneration &+= 1
        return playbackGeneration
    }

    mutating func updatePosition(
        renderSampleTime: Int64,
        sampleRate: Double,
        anchorPosition: TimeInterval,
        outputLatency: TimeInterval = 0
    ) {
        position = calculatedPosition(
            renderSampleTime: renderSampleTime,
            sampleRate: sampleRate,
            anchorPosition: anchorPosition,
            outputLatency: outputLatency
        )
    }

    /// The playhead implied by the render clock, in source-song seconds.
    ///
    /// `outputLatency` is how far ahead of the speaker the engine renders —
    /// the audio session's output latency plus its I/O buffer. Subtracting it
    /// makes the reported position describe what the user is *hearing* rather
    /// than what has been handed to the hardware, which on Bluetooth routes
    /// differ by well over 100 ms. It is given in render seconds and scaled by
    /// `rate` into source seconds, like the rest of the elapsed time.
    func calculatedPosition(
        renderSampleTime: Int64,
        sampleRate: Double,
        anchorPosition: TimeInterval,
        outputLatency: TimeInterval = 0
    ) -> TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0, anchorPosition.isFinite else {
            return position
        }
        let latency = outputLatency.isFinite ? max(0, outputLatency) : 0
        let elapsedRenderTime = max(
            0,
            Double(renderSampleTime) / sampleRate - latency
        )
        let elapsedMediaTime = elapsedRenderTime * Double(rate)
        let unwrappedPosition = anchorPosition + elapsedMediaTime
        if let loopRange, unwrappedPosition >= loopRange.end {
            let offset = (unwrappedPosition - loopRange.start)
                .truncatingRemainder(dividingBy: loopRange.duration)
            return loopRange.start + max(0, offset)
        }
        return min(duration, max(0, unwrappedPosition))
    }

    private static func validDuration(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite ? max(0, duration) : 0
    }

    init() {}
}
