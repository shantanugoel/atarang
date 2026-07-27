import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

/// The one frequently-changing value the lyrics view reads.
///
/// It is a separate object from the store on purpose. The store holds the lines
/// — hundreds of them, changing only when the user edits — and the playhead
/// holds two integers that change while the song plays. Keeping them apart is
/// what stops a line change from invalidating every view that reads the lyrics
/// themselves; only the rows, which are leaves, re-evaluate.
@MainActor
@Observable
final class LyricsPlayhead {
    /// The line the playhead is inside, as an index into `SongLyrics.lines`.
    var lineIndex: Int?
    /// Whole seconds until the next vocal entry, during a long instrumental
    /// gap. `nil` at every other moment.
    var countdown: Int?

    func clear() {
        lineIndex = nil
        countdown = nil
    }
}

/// A song's words, for as long as that song is open.
///
/// Lyrics live beside the *original* like everything else the app knows about a
/// song, so they survive re-separating with a different model. Writes are small
/// and infrequent — a paste, an import, a corrected line — so each one goes to
/// disk immediately rather than through a throttle; there is no equivalent of
/// the playhead position writing itself twice a second.
@MainActor
@Observable
final class LyricsStore {
    /// What the store needs to know about the song the lyrics belong to.
    struct Song: Equatable, Sendable {
        var storage: SongStorage
        var title: String
        var sourceURL: URL?
        var duration: TimeInterval
    }

    private(set) var song: Song?
    private(set) var lyrics: SongLyrics?
    /// Something that went wrong in a way the user has to be told about — a
    /// file that would not parse, a lookup that failed.
    var errorMessage: String?

    @ObservationIgnored let playhead = LyricsPlayhead()

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Lyrics"
    )

    var hasLyrics: Bool { !(lyrics?.isEmpty ?? true) }
    var isLoaded: Bool { song != nil }

    /// True when captions could be fetched for this song, which is only when we
    /// still know where it came from.
    var captionSourceURL: URL? {
        guard let sourceURL = song?.sourceURL else { return nil }
        return YouTubeSource.validatedURL(from: sourceURL.absoluteString)
    }

    // MARK: - Lifecycle

    func open(track: LocalTrack, duration: TimeInterval) {
        let storage = track.songStorage
        song = Song(
            storage: storage,
            title: track.title,
            sourceURL: track.sourceURL,
            duration: duration
        )
        playhead.clear()
        errorMessage = nil
        // Read without the version gate `readAnalysis` applies. Lyrics are the
        // one artifact that is partly the user's own work, and no version bump
        // makes words they typed or times they tapped stale.
        var loaded = storage.read(SongLyrics.self, from: SongLyrics.filename)
        loaded?.sanitize(duration: duration)
        lyrics = loaded
    }

    func close() {
        song = nil
        lyrics = nil
        playhead.clear()
        errorMessage = nil
    }

    // MARK: - Playhead

    /// Called from the 10 Hz position path, not at display rate: a line change
    /// and a whole-second countdown are both far below that.
    func updatePlayhead(position: TimeInterval) {
        guard let lyrics else {
            playhead.clear()
            return
        }
        let index = lyrics.lineIndex(at: position)
        if playhead.lineIndex != index { playhead.lineIndex = index }
        let countdown = lyrics.vocalEntryCountdown(at: position)
            .map { max(1, Int($0.secondsRemaining.rounded(.up))) }
        if playhead.countdown != countdown { playhead.countdown = countdown }
    }

    // MARK: - Mutation

    /// Replaces the whole set, which is what an import or a lookup does.
    func replace(with newLyrics: SongLyrics) {
        guard let song else { return }
        var value = newLyrics
        value.sanitize(duration: song.duration)
        value.updatedAt = Date()
        lyrics = value
        save()
        updatePlayhead(position: 0)
    }

    /// Edits in place. Every caller here is a user action, so the result is
    /// written straight away.
    func update(_ body: (inout SongLyrics) -> Void) {
        guard var value = lyrics, let song else { return }
        body(&value)
        value.sanitize(duration: song.duration)
        value.updatedAt = Date()
        lyrics = value
        save()
    }

    func clear() {
        guard let song else { return }
        lyrics = nil
        playhead.clear()
        song.storage.remove(SongLyrics.filename)
    }

    private func save() {
        guard let song, let lyrics else { return }
        do {
            try song.storage.write(lyrics, to: SongLyrics.filename)
        } catch {
            logger.error(
                "Could not save lyrics: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "The lyrics could not be saved to this device."
        }
    }

    // MARK: - Files

    /// Reads an `.lrc` — or any plain text file — the user handed us from the
    /// document picker or the share sheet.
    func importFile(at url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = "That file could not be read as text."
            return
        }
        let parsed = LyricsFormat.parseLRC(text)
        guard !parsed.isEmpty else {
            errorMessage = "That file contained no lyrics."
            return
        }
        replace(with: parsed)
    }

    /// Writes the current lyrics somewhere shareable, and returns where.
    func exportFile() throws -> URL {
        guard let song, let lyrics else { throw LyricsError.nothingToExport }
        let name = song.title
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(
            "\(name.isEmpty ? "Lyrics" : name).lrc"
        )
        try LyricsFormat.lrcString(from: lyrics, title: song.title)
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

enum LyricsError: LocalizedError {
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .nothingToExport: "There are no lyrics to export yet."
        }
    }
}

extension UTType {
    /// `.lrc` has no system-declared type, so the app declares one and this is
    /// the Swift side of that declaration.
    static let lrcLyrics = UTType(
        exportedAs: "com.shantanugoel.atarang.lrc",
        conformingTo: .plainText
    )
}
