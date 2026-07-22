import SwiftUI

enum StemKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case vocals, drums, bass, other

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .vocals: "music.microphone"
        case .drums: "metronome"
        case .bass: "guitars.fill"
        case .other: "pianokeys"
        }
    }
    var color: Color {
        switch self {
        case .vocals: .pink
        case .drums: .orange
        case .bass: .blue
        case .other: .purple
        }
    }
}

struct LocalTrack: Identifiable, Sendable {
    let id: UUID
    let title: String
    let files: [StemKind: URL]
    let createdAt: Date
    let sourceURL: URL?
}

struct RecordedTake: Identifiable, Sendable {
    let id: UUID
    let title: String
    let microphoneURL: URL
    let backingURL: URL
    let duration: TimeInterval
    let createdAt: Date
}

struct TrackMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let sourceURL: URL?
}

struct RecordingMetadata: Codable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let sourceTrackID: UUID?
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
