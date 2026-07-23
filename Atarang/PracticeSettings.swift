import Foundation

enum StudioWorkspace: String, Codable, CaseIterable, Identifiable, Sendable {
    case mix
    case practice

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum TargetMixPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case learn
    case guide
    case playAlong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .learn: "Learn"
        case .guide: "Guide"
        case .playAlong: "Play Along"
        }
    }

    var detail: String {
        switch self {
        case .learn: "Hear the target by itself"
        case .guide: "Keep the target quiet with the backing"
        case .playAlong: "Mute the target and take its place"
        }
    }
}

struct SongPracticeSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let supportedCountInClicks = [0, 2, 4]

    var schemaVersion = Self.currentSchemaVersion
    var workspace: StudioWorkspace = .mix
    var target: StemKind?
    var preset: TargetMixPreset = .learn
    var loopStart: TimeInterval?
    var loopEnd: TimeInterval?
    var isLoopEnabled = false
    var playbackRate: Float = 1
    var countInClicks = 0
    var lastPosition: TimeInterval = 0

    var loopRange: (start: TimeInterval, end: TimeInterval)? {
        guard let loopStart, let loopEnd else { return nil }
        return (loopStart, loopEnd)
    }

    mutating func validate(duration: TimeInterval, availableStems: [StemKind]) {
        schemaVersion = Self.currentSchemaVersion
        playbackRate = min(
            max(playbackRate, PlaybackState.supportedRateRange.lowerBound),
            PlaybackState.supportedRateRange.upperBound
        )
        countInClicks = Self.supportedCountInClicks.contains(countInClicks)
            ? countInClicks
            : 0
        lastPosition = lastPosition.isFinite
            ? min(max(0, lastPosition), max(0, duration))
            : 0

        if let target, !availableStems.contains(target) {
            self.target = nil
        }
        if target == nil {
            target = availableStems.contains(.vocals) ? .vocals : availableStems.first
        }

        guard let start = loopStart,
              let end = loopEnd,
              let range = PlaybackLoopRange(start: start, end: end, duration: duration) else {
            loopStart = nil
            loopEnd = nil
            isLoopEnabled = false
            return
        }
        loopStart = range.start
        loopEnd = range.end
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspace, target, preset, loopStart, loopEnd
        case isLoopEnabled, playbackRate, countInClicks, lastPosition
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = Self.currentSchemaVersion
        workspace = try values.decodeIfPresent(
            StudioWorkspace.self,
            forKey: .workspace
        ) ?? .mix
        target = try values.decodeIfPresent(StemKind.self, forKey: .target)
        preset = try values.decodeIfPresent(
            TargetMixPreset.self,
            forKey: .preset
        ) ?? .learn
        loopStart = try values.decodeIfPresent(TimeInterval.self, forKey: .loopStart)
        loopEnd = try values.decodeIfPresent(TimeInterval.self, forKey: .loopEnd)
        isLoopEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .isLoopEnabled
        ) ?? false
        playbackRate = try values.decodeIfPresent(
            Float.self,
            forKey: .playbackRate
        ) ?? 1
        countInClicks = try values.decodeIfPresent(
            Int.self,
            forKey: .countInClicks
        ) ?? 0
        lastPosition = try values.decodeIfPresent(
            TimeInterval.self,
            forKey: .lastPosition
        ) ?? 0
    }
}

struct PracticeSettingsStore {
    private static let keyPrefix = "practiceSettings.v1."
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(for trackID: UUID) -> SongPracticeSettings {
        guard let data = defaults.data(forKey: Self.keyPrefix + trackID.uuidString),
              let settings = try? JSONDecoder().decode(
                SongPracticeSettings.self,
                from: data
              ) else {
            return SongPracticeSettings()
        }
        return settings
    }

    func save(_ settings: SongPracticeSettings, for trackID: UUID) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.keyPrefix + trackID.uuidString)
    }

    func reset(for trackID: UUID) {
        defaults.removeObject(forKey: Self.keyPrefix + trackID.uuidString)
    }
}
