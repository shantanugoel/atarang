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
}

struct LocalTrack: Identifiable, Sendable {
    let id: UUID
    let title: String
    let files: [StemKind: URL]
    let createdAt: Date
    let sourceURL: URL?
    let separationModel: SeparationModelKind
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
    let separationModel: SeparationModelKind
    let stems: [StemKind]

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        sourceURL: URL?,
        separationModel: SeparationModelKind,
        stems: [StemKind]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.separationModel = separationModel
        self.stems = stems
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, sourceURL, separationModel, stems
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        sourceURL = try values.decodeIfPresent(URL.self, forKey: .sourceURL)
        separationModel = try values.decodeIfPresent(
            SeparationModelKind.self,
            forKey: .separationModel
        ) ?? .htdemucs
        stems = try values.decodeIfPresent([StemKind].self, forKey: .stems)
            ?? SeparationModelKind.htdemucs.stems
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
