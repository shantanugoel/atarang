import Foundation

struct PlaybackLoopRange: Codable, Equatable, Sendable {
    static let minimumDuration: TimeInterval = 0.1

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
struct PlaybackState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let supportedRateRange: ClosedRange<Float> = 0.5...1.0
    static let supportedPitchRange: ClosedRange<Float> = -12...12

    private(set) var schemaVersion = Self.currentSchemaVersion
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
        anchorPosition: TimeInterval
    ) {
        position = calculatedPosition(
            renderSampleTime: renderSampleTime,
            sampleRate: sampleRate,
            anchorPosition: anchorPosition
        )
    }

    func calculatedPosition(
        renderSampleTime: Int64,
        sampleRate: Double,
        anchorPosition: TimeInterval
    ) -> TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0, anchorPosition.isFinite else {
            return position
        }
        let elapsedMediaTime = max(0, Double(renderSampleTime) / sampleRate) * Double(rate)
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

    private static func validatedLoop(
        _ range: PlaybackLoopRange?,
        duration: TimeInterval
    ) -> PlaybackLoopRange? {
        guard let range else { return nil }
        return PlaybackLoopRange(start: range.start, end: range.end, duration: duration)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, position, duration, rate, pitchSemitones, loopRange
        case playbackGeneration
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = Self.currentSchemaVersion
        duration = Self.validDuration(
            try values.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        )
        let decodedPosition = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .position
        ) ?? 0
        position = decodedPosition.isFinite ? min(max(0, decodedPosition), duration) : 0
        setRate(try values.decodeIfPresent(Float.self, forKey: .rate) ?? 1)
        setPitchSemitones(
            try values.decodeIfPresent(Float.self, forKey: .pitchSemitones) ?? 0
        )
        loopRange = Self.validatedLoop(
            try values.decodeIfPresent(PlaybackLoopRange.self, forKey: .loopRange),
            duration: duration
        )
        playbackGeneration = max(
            0,
            try values.decodeIfPresent(Int.self, forKey: .playbackGeneration) ?? 0
        )
    }
}
