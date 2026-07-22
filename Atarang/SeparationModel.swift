import Foundation
import Combine
import YoutubeDL

@MainActor
final class SeparationModel: ObservableObject {
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var statusText = "Preparing…"
    @Published var errorMessage: String?

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
            let downloaded = try await downloadAudio(from: url)
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
            try? FileManager.default.removeItem(at: downloaded.url)
            progress = 1
            statusText = "Ready to play"
            return LocalTrack(title: downloaded.title, files: files)
        } catch {
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    private func downloadAudio(from url: URL) async throws -> (url: URL, title: String) {
        let youtubeDL = YoutubeDL()
        let (formats, info) = try await youtubeDL.extractInfo(url: url)
        let supportedExtensions = Set(["m4a", "mp4", "aac"])
        let compatibleFormats = formats.filter { format in
            format.isAudioOnly && supportedExtensions.contains(format.ext.lowercased())
        }
        let bestFormat = compatibleFormats.max { first, second in
            let firstRate = first.abr ?? first.tbr ?? 0
            let secondRate = second.abr ?? second.tbr ?? 0
            return firstRate < secondRate
        }
        guard let format = bestFormat, let request = format.urlRequest else {
            throw SeparationFailure.noCompatibleAudio
        }

        statusText = "Downloading audio to this iPhone…"
        progress = 0.08
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SeparationFailure.downloadFailed
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.ext)
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress = 0.16
        return (destination, info.title)
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

private enum SeparationFailure: LocalizedError {
    case noCompatibleAudio
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudio: "YouTube did not provide an iPhone-compatible audio stream for this video."
        case .downloadFailed: "YouTube refused the audio download. Try updating the app's yt-dlp module or use another video."
        }
    }
}
