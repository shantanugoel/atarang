import Foundation
import Combine
import OSLog
import YoutubeDL

@MainActor
final class SeparationModel: ObservableObject {
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var statusText = "Preparing…"
    @Published var errorMessage: String?
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Separation")

    func separate(youtubeURL: String) async -> LocalTrack? {
        guard let url = URL(string: youtubeURL), isYouTubeURL(url) else {
            errorMessage = "Enter a valid youtube.com or youtu.be URL."
            return nil
        }

        isWorking = true
        progress = 0.01
        statusText = "Reading video information…"
        defer { isWorking = false }

        do {
            statusText = "Preparing bundled yt-dlp…"
            try BundledYTDLP.install()
            progress = 0.03
            logger.info("Starting extraction for \(url.absoluteString, privacy: .public) with bundled yt-dlp \(BundledYTDLP.version, privacy: .public)")

            let slowNotice = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.statusText = "YouTube is taking longer than expected…"
            }
            defer { slowNotice.cancel() }
            let downloaded = try await downloadAudio(from: url)
            logger.info("Audio download complete: \(downloaded.url.lastPathComponent, privacy: .public)")
            statusText = "Loading on-device Demucs…"
            progress = 0.18
            let separator = try StemSeparator()
            let folder = try outputFolder()
            let files = try await separator.separate(fileURL: downloaded.url, outputFolder: folder) { value in
                Task { @MainActor [weak self] in
                    self?.statusText = "Separating four stems on this iPhone…"
                    self?.progress = 0.2 + value * 0.78
                }
            }
            try? FileManager.default.removeItem(at: downloaded.url.deletingLastPathComponent())
            progress = 1
            statusText = "Ready to play"
            logger.info("Separation completed successfully")
            return LocalTrack(title: downloaded.title, files: files)
        } catch {
            logger.error("Separation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    private func downloadAudio(from url: URL) async throws -> (url: URL, title: String) {
        statusText = "Reading YouTube video information…"
        progress = 0.06
        let extractionLogger = Logger(
            subsystem: "com.shantanugoel.atarang.Atarang",
            category: "yt-dlp-download"
        )
        let selection = try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Atarang-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let metadataURL = folder.appendingPathComponent("selection.json")
            let printTemplate = "{\"title\":%(title)j,\"url\":%(url)j,\"headers\":%(http_headers)j,\"size\":%(filesize)j}"

            try await yt_dlp(
                argv: [
                    "--no-playlist",
                    "--no-check-certificates",
                    "--no-warnings",
                    "--skip-download",
                    "--format", "bestaudio[ext=m4a]",
                    "--print-to-file", printTemplate, metadataURL.path,
                    url.absoluteString,
                ],
                log: { level, message in
                    extractionLogger.debug("[\(level, privacy: .public)] \(message, privacy: .public)")
                }
            )
            let data = try Data(contentsOf: metadataURL)
            var decoded = try JSONDecoder().decode(YTDLPSelection.self, from: data)
            decoded.temporaryFolder = folder
            return decoded
        }.value

        guard let mediaURL = URL(string: selection.url) else {
            throw SeparationFailure.noCompatibleAudio
        }
        statusText = "Downloading audio to this iPhone…"
        progress = 0.1
        var request = URLRequest(url: mediaURL)
        selection.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let size = selection.size, size > 0 {
            request.setValue("bytes=0-\(size - 1)", forHTTPHeaderField: "Range")
        }
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SeparationFailure.httpStatus(code)
        }
        let destination = selection.temporaryFolder.appendingPathComponent("source.m4a")
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress = 0.16
        return (destination, selection.title)
    }

    private func outputFolder() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tracks", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "The download failed: \(urlError.localizedDescription). Check your connection and try again."
        }
        return error.localizedDescription
    }
}

private struct YTDLPSelection: Decodable, @unchecked Sendable {
    let title: String
    let url: String
    let headers: [String: String]
    let size: Int?
    var temporaryFolder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case title, url, headers, size
    }
}

private enum SeparationFailure: LocalizedError {
    case noCompatibleAudio
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudio: "YouTube did not provide an iPhone-compatible audio stream for this video."
        case .httpStatus(let code): "YouTube refused the audio download (HTTP \(code))."
        }
    }
}
