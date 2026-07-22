import SwiftUI

enum StemKind: String, CaseIterable, Identifiable {
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

struct LocalTrack {
    let title: String
    let files: [StemKind: URL]
}

struct RecordedTake: Identifiable, Sendable {
    let id: UUID
    let title: String
    let microphoneURL: URL
    let backingURL: URL
    let duration: TimeInterval
    let createdAt: Date
}
