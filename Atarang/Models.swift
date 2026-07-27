import SwiftUI

enum StemKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case vocals, instrumental, drums, bass, guitar, piano, other

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .vocals: "music.microphone"
        case .instrumental: "music.note.list"
        case .drums: "metronome"
        case .bass: "guitars.fill"
        case .guitar: "guitars"
        case .piano: "pianokeys.inverse"
        case .other: "pianokeys"
        }
    }
    var color: Color {
        switch self {
        case .vocals: .pink
        case .instrumental: .indigo
        case .drums: .orange
        case .bass: .blue
        case .guitar: .green
        case .piano: .mint
        case .other: .purple
        }
    }
}

enum SeparationModelKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case htdemucs
    case htdemucs6s
    case mdx23cInstVocHQ
    case kimVocals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .htdemucs: "HTDemucs"
        case .htdemucs6s: "HTDemucs 6-stem"
        case .mdx23cInstVocHQ: "MDX23C InstVoc HQ"
        case .kimVocals: "Kim Vocals"
        }
    }

    var detail: String {
        switch self {
        case .htdemucs: "Balanced four-stem separation"
        case .htdemucs6s: "Adds dedicated guitar and piano stems"
        case .mdx23cInstVocHQ: "High-quality vocals and instrumental"
        case .kimVocals: "Vocal-focused vocals and instrumental"
        }
    }

    /// The output order baked into each Core ML model.
    var stems: [StemKind] {
        switch self {
        case .htdemucs: [.vocals, .drums, .bass, .other]
        case .htdemucs6s: [.vocals, .drums, .bass, .other, .guitar, .piano]
        case .mdx23cInstVocHQ, .kimVocals: [.vocals, .instrumental]
        }
    }

    var resourceName: String {
        switch self {
        case .htdemucs: "HTDemucs_CoreML_FP16"
        case .htdemucs6s: "HTDemucs_6S_CoreML_FP16"
        case .mdx23cInstVocHQ: "MDX23C_InstVoc_HQ_CoreML"
        case .kimVocals: "Kim_Vocals_CoreML"
        }
    }

    var stemSummary: String { stems.map(\.title).joined(separator: ", ") }

    /// What the user gets, named as an outcome. The architecture name is still
    /// available as `title`, but it is secondary detail now: "MDX23C InstVoc HQ"
    /// tells someone deciding what to separate almost nothing.
    var outcomeTitle: String {
        switch self {
        case .htdemucs: "Balanced 4-stem"
        case .htdemucs6s: "Detailed 6-stem"
        case .mdx23cInstVocHQ: "Vocals + Backing"
        case .kimVocals: "Vocals + Backing, vocal-focused"
        }
    }

    var outcomeDetail: String {
        switch self {
        case .htdemucs: "Vocals, drums, bass, and everything else. The right default for playing along."
        case .htdemucs6s: "Adds separate guitar and piano, so you can mute exactly your part."
        case .mdx23cInstVocHQ: "The cleanest vocal split, when all you need is the singer removed."
        case .kimVocals: "A second opinion on the vocal split; try it when the first leaves artefacts."
        }
    }

    /// How long it takes relative to the others, in words rather than numbers:
    /// the real figure depends entirely on the device.
    var speedClass: String {
        switch self {
        case .htdemucs: "Moderate"
        case .htdemucs6s: "Slowest"
        case .mdx23cInstVocHQ, .kimVocals: "Fastest"
        }
    }

    /// Badged, not enforced. The recommendation exists to make the first choice
    /// easy, not to hide the others.
    static var recommendedForCurrentDevice: SeparationModelKind {
        htdemucs.isAvailableOnCurrentDevice ? .htdemucs : .mdx23cInstVocHQ
    }

    /// What to pick instead when this one cannot run here.
    var suggestedAlternative: SeparationModelKind? {
        guard !isAvailableOnCurrentDevice else { return nil }
        return Self.recommendedForCurrentDevice
    }

    var choiceTitle: String {
        switch self {
        case .htdemucs: "4 stems — Recommended"
        case .htdemucs6s: "6 stems — Most control"
        case .mdx23cInstVocHQ: "Vocals + backing — High quality"
        case .kimVocals: "Vocals + backing — Vocal focused"
        }
    }

    var shortChoiceTitle: String {
        switch self {
        case .htdemucs: "4 stems"
        case .htdemucs6s: "6 stems"
        case .mdx23cInstVocHQ, .kimVocals: "Vocals + backing"
        }
    }

    var recommendationLabel: String? {
        switch self {
        case .htdemucs: "Recommended"
        case .htdemucs6s: "Most control"
        case .mdx23cInstVocHQ: "High quality"
        case .kimVocals: "Vocal focused"
        }
    }

    var downloadSize: String? {
        switch self {
        case .htdemucs: nil
        case .htdemucs6s: "136 MB"
        case .mdx23cInstVocHQ: "40 MB"
        case .kimVocals: "67 MB"
        }
    }

    var performanceHint: String {
        switch self {
        case .htdemucs: "Balanced quality and speed"
        case .htdemucs6s: "Slowest; best for detailed instrument control"
        case .mdx23cInstVocHQ: "Best general two-track vocal split"
        case .kimVocals: "Alternative vocal-focused character"
        }
    }

    /// Increment this when a model or its output processing changes incompatibly.
    var separationCacheVersion: Int { 1 }

    /// How much free memory this model needs, or `nil` when it runs anywhere.
    ///
    /// Consulted twice: once when the user picks a model, so an unusable choice
    /// is explained rather than offered, and again by `AnalysisQueue` when the
    /// job actually starts, which may be minutes and one memory warning later.
    var minimumAvailableMemoryBytes: UInt64? {
        switch self {
        case .htdemucs6s: ModelMemoryBudget.sixStemMinimumAvailableBytes
        default: nil
        }
    }

    var isAvailableOnCurrentDevice: Bool {
        guard let minimumAvailableMemoryBytes else { return true }
        return ModelMemoryBudget.hasHeadroom(forBytes: minimumAvailableMemoryBytes)
    }

    var unavailabilityMessage: String? {
        guard !isAvailableOnCurrentDevice else { return nil }
        return "6-stem needs a newer high-memory device or more free memory."
    }
}

struct LocalTrack: Identifiable, Sendable {
    let id: UUID
    let title: String
    let files: [StemKind: URL]
    let createdAt: Date
    let sourceURL: URL?
    let sourceOriginalID: UUID?
    let separationModel: SeparationModelKind
    /// `Tracks/<id>/`. Carried so song-scoped storage has somewhere to fall back
    /// to when the original this separation came from has been deleted.
    let folderURL: URL

    /// Where this song's practice state and analysis results live.
    var songStorage: SongStorage {
        SongStorage.resolve(originalID: sourceOriginalID, trackFolder: folderURL)
    }
}

struct OriginalMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let sourceURL: URL
    let sourceKey: String?
    let audioFilename: String

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        sourceURL: URL,
        sourceKey: String? = nil,
        audioFilename: String
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.sourceKey = sourceKey
        self.audioFilename = audioFilename
    }
}

struct RecordedTake: Identifiable, Sendable {
    let id: UUID
    let title: String
    let microphoneURL: URL
    let backingURL: URL
    let microphoneLevel: Float
    let backingLevel: Float
    let duration: TimeInterval
    let createdAt: Date
}

struct TrackMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let sourceURL: URL?
    let sourceKey: String?
    let sourceOriginalID: UUID?
    let separationModel: SeparationModelKind
    let separationCacheVersion: Int
    let stems: [StemKind]

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        sourceURL: URL?,
        sourceKey: String? = nil,
        sourceOriginalID: UUID?,
        separationModel: SeparationModelKind,
        separationCacheVersion: Int? = nil,
        stems: [StemKind]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.sourceKey = sourceKey
        self.sourceOriginalID = sourceOriginalID
        self.separationModel = separationModel
        self.separationCacheVersion = separationCacheVersion
            ?? separationModel.separationCacheVersion
        self.stems = stems
    }
}

struct RecordingMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let sourceTrackID: UUID?
    let microphoneLevel: Float?
    let backingLevel: Float?
    var exportedFilename: String?
}

extension Notification.Name {
    static let atarangLibraryDidChange = Notification.Name("AtarangLibraryDidChange")
}

enum LibraryMetadata {
    static let originalFilename = "original.json"
    static let trackFilename = "track.json"
    static let recordingFilename = "recording.json"

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}
