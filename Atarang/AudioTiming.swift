import AVFoundation
import Foundation

/// Pure timing helpers shared by the player.
///
/// Everything here is a value type or a static function over plain numbers so
/// the parts of playback that are easy to get wrong — which stem owns the
/// clock, where a metronome click lands, how often practice state is written —
/// can be unit-tested without an audio engine.

// MARK: - Stem scheduling

/// The frame range one stem file contributes for a source-time range.
struct ScheduledSegment: Equatable, Sendable {
    let startingFrame: AVAudioFramePosition
    let frameCount: AVAudioFrameCount

    var isEmpty: Bool { frameCount == 0 }
}

/// The subset of an `AVAudioFile` that scheduling depends on.
struct StemFileGeometry: Equatable, Sendable {
    let length: AVAudioFramePosition
    let sampleRate: Double
}

enum StemScheduling {
    /// Converts a source-time range into the frames one file can supply.
    ///
    /// Every stem is asked for the same source range, so stems recorded at
    /// different sample rates stay aligned in source seconds rather than in
    /// frames.
    static func segment(
        for geometry: StemFileGeometry,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> ScheduledSegment {
        guard geometry.sampleRate > 0, geometry.sampleRate.isFinite,
              start.isFinite, end.isFinite else {
            return ScheduledSegment(startingFrame: 0, frameCount: 0)
        }
        let startingFrame = min(
            geometry.length,
            AVAudioFramePosition(max(0, start) * geometry.sampleRate)
        )
        let endingFrame = min(
            geometry.length,
            AVAudioFramePosition(max(start, end) * geometry.sampleRate)
        )
        return ScheduledSegment(
            startingFrame: startingFrame,
            frameCount: AVAudioFrameCount(max(0, endingFrame - startingFrame))
        )
    }

    /// Picks the stem that owns position updates and loop completions.
    ///
    /// The first active stem is preferred so the choice is stable, but a stem
    /// that schedules zero frames — a short or truncated file, or a range past
    /// its end — cannot report progress or fire a completion. Falling through
    /// to the next stem keeps the playhead and looping alive instead of
    /// stalling silently.
    static func timingStem(
        among stems: [StemKind],
        geometry: (StemKind) -> StemFileGeometry?,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> StemKind? {
        stems.first { stem in
            guard let stemGeometry = geometry(stem) else { return false }
            return !segment(for: stemGeometry, from: start, to: end).isEmpty
        }
    }
}

// MARK: - Metronome clicks

/// One scheduled metronome click.
///
/// `sourceTime` is in source-song seconds; `renderTime` is seconds since the
/// player node started, which is what `AVAudioPlayerNode.scheduleBuffer(at:)`
/// needs.
struct MetronomeClick: Equatable, Sendable {
    let index: Int
    let sourceTime: TimeInterval
    let renderTime: TimeInterval
    let isAccented: Bool
}

/// The click grid for one scheduled playback pass.
///
/// Clicks are produced on demand for a rolling render-time window rather than
/// synthesized for the whole remaining song, so enabling the metronome costs
/// the same whether the loop is four bars or the track is nine minutes long.
struct MetronomeClickPlan: Equatable, Sendable {
    static let beatsPerAccent = 4

    /// Source seconds where this pass begins, matching the stems' range.
    var sourceStart: TimeInterval = 0
    /// Source seconds where this pass ends.
    var sourceEnd: TimeInterval = 0
    /// Render seconds since the node started at which this pass begins.
    var renderOrigin: TimeInterval = 0
    var bpm: Double = 120
    var clicksPerBeat: Int = 1
    /// The source time of click index zero.
    var alignment: TimeInterval = 0
    var accentsEnabled = true
    var rate: Double = 1
    /// The next click index still to be scheduled.
    private(set) var nextIndex = 0

    var isValid: Bool {
        bpm > 0 && clicksPerBeat > 0 && rate > 0
            && sourceEnd > sourceStart
            && [bpm, alignment, sourceStart, sourceEnd, renderOrigin, rate]
                .allSatisfy(\.isFinite)
    }

    var clickInterval: TimeInterval { 60 / bpm / Double(clicksPerBeat) }

    /// Rewinds the cursor to the first click at or after `sourceStart`.
    mutating func reset() {
        guard isValid else {
            nextIndex = 0
            return
        }
        nextIndex = Int(((sourceStart - alignment) / clickInterval).rounded(.up))
    }

    /// Returns every unscheduled click that begins at or before
    /// `renderDeadline`, advancing the cursor past them.
    mutating func clicks(through renderDeadline: TimeInterval) -> [MetronomeClick] {
        guard isValid, renderDeadline.isFinite else { return [] }
        var result: [MetronomeClick] = []
        let beatDuration = 60 / bpm
        while true {
            let index = nextIndex
            let sourceTime = alignment + Double(index) * clickInterval
            guard sourceTime < sourceEnd else { return result }
            let renderTime = renderOrigin + (sourceTime - sourceStart) / rate
            guard renderTime <= renderDeadline else { return result }
            nextIndex = index + 1
            guard sourceTime >= sourceStart, renderTime >= 0 else { continue }
            let subdivision = ((index % clicksPerBeat) + clicksPerBeat) % clicksPerBeat
            let beat = Int(((sourceTime - alignment) / beatDuration).rounded(.down))
            let isDownbeat = subdivision == 0
                && ((beat % Self.beatsPerAccent) + Self.beatsPerAccent)
                    % Self.beatsPerAccent == 0
            result.append(
                MetronomeClick(
                    index: index,
                    sourceTime: sourceTime,
                    renderTime: renderTime,
                    isAccented: isDownbeat && accentsEnabled
                )
            )
        }
    }
}

// MARK: - Write throttling

/// Rate-limits a write, remembering when one was suppressed.
///
/// Practice state changes far faster than it needs to reach disk: a single
/// seek used to encode and store the whole settings blob twice. Callers ask
/// `shouldWrite` before every save and consult `hasPendingWrite` to flush the
/// last suppressed one before the state can be lost.
struct WriteThrottle: Equatable, Sendable {
    let interval: TimeInterval
    private(set) var lastWrite: Date
    private(set) var hasPendingWrite = false

    init(interval: TimeInterval, lastWrite: Date = .distantPast) {
        self.interval = interval
        self.lastWrite = lastWrite
    }

    /// Records either a write or a suppressed write, and reports which.
    mutating func shouldWrite(now: Date = Date(), force: Bool = false) -> Bool {
        guard force || now.timeIntervalSince(lastWrite) >= interval else {
            hasPendingWrite = true
            return false
        }
        lastWrite = now
        hasPendingWrite = false
        return true
    }

    /// Seconds until a suppressed write would be allowed through.
    func delayUntilNextWrite(now: Date = Date()) -> TimeInterval {
        max(0, interval - now.timeIntervalSince(lastWrite))
    }

    mutating func reset() {
        lastWrite = .distantPast
        hasPendingWrite = false
    }
}
