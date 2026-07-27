import Foundation
import OSLog

/// The two places lyrics can come from without the user typing them.
///
/// Both are opt-in acts: captions are fetched only when the user asks for this
/// song, and the online database is not contacted at all unless the preference
/// in Settings is on. Neither ever replaces lyrics silently — both hand back a
/// candidate for the preview to show.
enum LyricsLookup {
    /// Off by default, and the only switch that allows a request to leave the
    /// device for lyrics.
    static let onlineLookupDefaultsKey = "lyricsOnlineLookupEnabled"

    static var isOnlineLookupEnabled: Bool {
        UserDefaults.standard.bool(forKey: onlineLookupDefaultsKey)
    }

    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Lyrics"
    )

    // MARK: - YouTube captions

    /// Fetches a video's caption track and reads it as lyrics.
    ///
    /// Runs through the shared queue like every other long job: it drives the
    /// same non-reentrant Python interpreter a separation does, and it should
    /// not start during a take.
    static func youTubeCaptions(for url: URL, title: String) async throws -> SongLyrics? {
        try await AnalysisQueue.shared.submit(
            kind: .captions,
            title: title
        ) { context in
            await context.report("Asking YouTube for captions…", progress: 0.2)
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("AtarangCaptions-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }

            logger.info("Fetching captions for \(url.absoluteString, privacy: .public)")
            try await BundledYTDLP.shared.run(argv: [
                "--no-playlist",
                "--no-check-certificates",
                "--no-warnings",
                "--skip-download",
                "--write-subs",
                "--write-auto-subs",
                // Exactly one track. `en.*` looked like the thorough choice and
                // is the opposite: it matches every auto-translated variant a
                // video carries — seven of them on the first song this was tried
                // against — so yt-dlp downloads all seven in a row, YouTube
                // answers 429, and the retries leave the sheet spinning. Plain
                // `en` is the manual English track when there is one and the
                // automatic one otherwise, which is the file we would have kept.
                "--sub-langs", "en",
                "--sub-format", "vtt",
                // These are the difference between a slow fetch and one that
                // never ends. Python's urllib has no default timeout, and
                // `BundledYTDLP` is an actor, so one stalled socket would hold
                // up every later yt-dlp call — a separation included.
                "--socket-timeout", "15",
                "--retries", "2",
                "--extractor-retries", "1",
                "-o", folder.appendingPathComponent("captions.%(ext)s").path,
                url.absoluteString,
            ])
            try Task.checkCancellation()
            await context.report("Reading captions…", progress: 0.8)

            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
            guard let vtt = files.first(where: { $0.pathExtension.lowercased() == "vtt" }),
                  let text = try? String(contentsOf: vtt, encoding: .utf8) else {
                logger.info("No caption track was written for this video")
                return nil
            }
            let lines = LyricsFormat.parseWebVTT(text)
            guard !lines.isEmpty else {
                logger.info("The caption track contained no readable cues")
                return nil
            }
            await context.report("Captions ready", progress: 1)
            logger.info("Parsed \(lines.count, privacy: .public) caption lines")
            return SongLyrics(
                source: .youtubeCaptions,
                lines: lines,
                attribution: "YouTube caption track"
            )
        }.value ?? nil
    }

    // MARK: - LRCLIB

    /// Searches LRCLIB for a song.
    ///
    /// The caller is responsible for the preference check; this refuses anyway,
    /// because a network call for lyrics is exactly the thing the preference
    /// exists to prevent and one forgotten check should not be enough to make
    /// it happen.
    static func searchOnline(
        track: String,
        artist: String,
        duration: TimeInterval
    ) async throws -> [OnlineLyricsMatch] {
        guard isOnlineLookupEnabled else { throw LyricsLookupError.onlineLookupDisabled }
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        var items = [URLQueryItem(name: "track_name", value: track)]
        if !artist.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "artist_name", value: artist))
        }
        components.queryItems = items
        guard let url = components.url else { throw LyricsLookupError.badRequest }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsLookupError.badRequest }
        guard (200..<300).contains(http.statusCode) else {
            throw LyricsLookupError.httpStatus(http.statusCode)
        }
        let records = try JSONDecoder().decode([LRCLIBRecord].self, from: data)
        return records
            .compactMap { OnlineLyricsMatch($0) }
            // Duration is the one field that can tell two recordings of the
            // same song apart, so the closest match to what is actually loaded
            // goes first.
            .sorted { left, right in
                left.durationDistance(to: duration) < right.durationDistance(to: duration)
            }
    }

    /// LRCLIB asks that clients identify themselves.
    private static var userAgent: String {
        let version = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Atarang/\(version) (https://github.com/shantanugoel/atarang)"
    }
}

/// One LRCLIB result, reduced to what the app can actually use and show.
struct OnlineLyricsMatch: Identifiable, Sendable, Equatable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String?
    let duration: TimeInterval?
    /// Whether the contributor supplied timings. A plain-text match is still
    /// worth taking — it becomes untimed lines for tap-to-timestamp.
    let isSynced: Bool
    let text: String

    init?(_ record: LRCLIBRecord) {
        let body = record.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = record.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text = (body?.isEmpty == false ? body : plain), !text.isEmpty else { return nil }
        id = record.id
        trackName = record.trackName ?? "Unknown track"
        artistName = record.artistName ?? "Unknown artist"
        albumName = record.albumName
        duration = record.duration
        isSynced = body?.isEmpty == false
        self.text = text
    }

    func durationDistance(to reference: TimeInterval) -> TimeInterval {
        guard let duration, reference > 0 else { return .greatestFiniteMagnitude }
        return abs(duration - reference)
    }

    var summary: String {
        var parts = [artistName]
        if let albumName, !albumName.isEmpty { parts.append(albumName) }
        if let duration { parts.append(StudioFormat.time(duration)) }
        return parts.joined(separator: " · ")
    }

    /// Synced results are `.lrc`; plain results are words with no times.
    var lyrics: SongLyrics {
        if isSynced {
            var parsed = LyricsFormat.parseLRC(text, source: .lrclib)
            parsed.attribution = "\(trackName) — \(artistName)"
            return parsed
        }
        return SongLyrics(
            source: .lrclib,
            lines: LyricsFormat.parsePlainText(text),
            attribution: "\(trackName) — \(artistName)"
        )
    }
}

struct LRCLIBRecord: Decodable, Sendable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsLookupError: LocalizedError {
    case onlineLookupDisabled
    case badRequest
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .onlineLookupDisabled:
            "Online lyrics lookup is turned off. Turn it on in Settings to search."
        case .badRequest:
            "That search could not be sent."
        case .httpStatus(let code):
            "The lyrics service refused the search (HTTP \(code))."
        }
    }
}
