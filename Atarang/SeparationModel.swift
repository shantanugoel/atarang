import AVFoundation
import Foundation
import Combine
import OSLog
import YoutubeDL

enum SeparationResult {
    case reused(LocalTrack)
    case created(LocalTrack)

    var track: LocalTrack {
        switch self {
        case .reused(let track), .created(let track): track
        }
    }

    var reusedExistingSeparation: Bool {
        if case .reused = self { return true }
        return false
    }
}

@MainActor
final class SeparationModel: ObservableObject {
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var statusText = "Preparing…"
    @Published var estimatedRemainingText: String?
    @Published var errorMessage: String?
    @Published var selectedModel: SeparationModelKind = .htdemucs
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Separation")
    private var separationStartedAt: Date?

    func existingSeparation(
        youtubeURL: String,
        using separationModel: SeparationModelKind
    ) -> LocalTrack? {
        guard let url = YouTubeSource.validatedURL(from: youtubeURL),
              let original = try? savedOriginal(for: url) else { return nil }
        return try? savedTrack(for: original, using: separationModel)
    }

    func existingSeparationModels(youtubeURL: String) -> [SeparationModelKind] {
        guard let url = YouTubeSource.validatedURL(from: youtubeURL),
              let original = try? savedOriginal(for: url) else { return [] }
        return SeparationModelKind.allCases.filter {
            (try? savedTrack(for: original, using: $0)) != nil
        }
    }

    func separate(
        youtubeURL: String,
        force: Bool = false
    ) async -> SeparationResult? {
        guard let url = YouTubeSource.validatedURL(from: youtubeURL) else {
            errorMessage = "Enter a valid youtube.com or youtu.be URL."
            return nil
        }

        isWorking = true
        let separationModel = selectedModel
        guard separationModel.isAvailableOnCurrentDevice else {
            isWorking = false
            errorMessage = separationModel.unavailabilityMessage
            return nil
        }
        progress = 0.01
        estimatedRemainingText = nil
        separationStartedAt = nil
        statusText = "Reading video information…"
        defer { isWorking = false }

        do {
            try Task.checkCancellation()
            let original: SavedOriginal
            if let existing = try savedOriginal(for: url) {
                original = existing
                statusText = "Using saved original…"
                progress = 0.17
            } else {
                statusText = "Preparing bundled yt-dlp…"
                try BundledYTDLP.install()
                progress = 0.09
                logger.info("Starting extraction for \(url.absoluteString, privacy: .public) with bundled yt-dlp \(BundledYTDLP.version, privacy: .public)")

                let slowNotice = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.statusText = "YouTube is taking longer than expected…"
                }
                defer { slowNotice.cancel() }
                let downloaded = try await downloadAudio(from: url)
                try Task.checkCancellation()
                slowNotice.cancel()
                original = try persistOriginal(
                    downloadedURL: downloaded.url,
                    title: downloaded.title,
                    sourceURL: url
                )
                try? FileManager.default.removeItem(
                    at: downloaded.url.deletingLastPathComponent()
                )
                NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
                logger.info("Audio saved to Originals")
            }
            if !force, let existing = try savedTrack(
                for: original,
                using: separationModel
            ) {
                progress = 1
                statusText = "Opened saved separation"
                return .reused(existing)
            }
            return .created(
                try await separate(original: original, using: separationModel)
            )
        } catch is CancellationError {
            statusText = "Cancelled"
            progress = 0
            return nil
        } catch {
            logger.error("Separation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    func separate(
        original: HistoryOriginal,
        using separationModel: SeparationModelKind,
        force: Bool = true
    ) async -> SeparationResult? {
        guard separationModel.isAvailableOnCurrentDevice else {
            errorMessage = separationModel.unavailabilityMessage
            return nil
        }
        isWorking = true
        selectedModel = separationModel
        progress = 0.17
        estimatedRemainingText = nil
        separationStartedAt = nil
        statusText = "Using saved original…"
        defer { isWorking = false }
        do {
            let savedOriginal = SavedOriginal(
                id: original.id,
                title: original.title,
                sourceURL: original.sourceURL,
                sourceKey: original.sourceKey
                    ?? YouTubeSource.canonicalKey(for: original.sourceURL),
                audioURL: original.audioURL
            )
            if !force, let existing = try savedTrack(
                for: savedOriginal,
                using: separationModel
            ) {
                progress = 1
                statusText = "Opened saved separation"
                return .reused(existing)
            }
            return .created(
                try await separate(
                    original: savedOriginal,
                    using: separationModel
                )
            )
        } catch is CancellationError {
            statusText = "Cancelled"
            progress = 0
            return nil
        } catch {
            logger.error("Separation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    private func separate(
        original: SavedOriginal,
        using separationModel: SeparationModelKind
    ) async throws -> LocalTrack {
        let availableMemory = ModelMemoryBudget.availableBytes
        logger.info(
            "Available memory before \(separationModel.title, privacy: .public): \(availableMemory, privacy: .public) bytes"
        )
        guard separationModel.isAvailableOnCurrentDevice else {
            throw StemSeparatorError.modelUnavailable(separationModel)
        }
        statusText = separationModel == .htdemucs
            ? "Loading \(separationModel.title)…"
            : "Preparing \(separationModel.title)…"
        let artifact = try await ModelAssetStore.shared.artifact(
            for: separationModel
        ) { [weak self] status, value in
            self?.statusText = status
            self?.progress = value
        }
        statusText = "Loading on-device \(separationModel.title)…"
        progress = 0.18
        let separator = try StemSeparator(
            modelKind: separationModel,
            artifact: artifact
        )
        try Task.checkCancellation()
        let output = try outputFolder()
        let files: [StemKind: URL]
        do {
            files = try await separator.separate(
                fileURL: original.audioURL,
                outputFolder: output.folder
            ) { value in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.separationStartedAt == nil {
                        self.separationStartedAt = Date()
                    }
                    self.statusText = "Separating \(separationModel.stems.count) stems on this device…"
                    self.progress = 0.2 + value * 0.78
                    self.updateEstimatedRemaining(forSeparationProgress: value)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: output.folder)
            throw error
        }

        progress = 1
        statusText = "Ready to mix"
        estimatedRemainingText = nil
        let createdAt = Date()
        let metadata = TrackMetadata(
            id: output.id,
            title: original.title,
            createdAt: createdAt,
            sourceURL: original.sourceURL,
            sourceKey: original.sourceKey,
            sourceOriginalID: original.id,
            separationModel: separationModel,
            stems: separationModel.stems
        )
        try LibraryMetadata.write(
            metadata,
            to: output.folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        logger.info("Separation completed successfully")
        return LocalTrack(
            id: output.id,
            title: original.title,
            files: files,
            createdAt: createdAt,
            sourceURL: original.sourceURL,
            sourceOriginalID: original.id,
            separationModel: separationModel
        )
    }

    private func downloadAudio(from url: URL) async throws -> (url: URL, title: String) {
        statusText = "Reading YouTube video information…"
        progress = 0.11
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
        statusText = "Downloading audio to this device…"
        progress = 0.14
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
        progress = 0.17
        return (destination, selection.title)
    }

    private func outputFolder() throws -> (id: UUID, folder: URL) {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Tracks", isDirectory: true)
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (id, folder)
    }

    private func persistOriginal(
        downloadedURL: URL,
        title: String,
        sourceURL: URL
    ) throws -> SavedOriginal {
        let root = try libraryRoot(named: "Originals")
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let audioURL = folder.appendingPathComponent("source.m4a")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: audioURL)
            try LibraryMetadata.write(
                OriginalMetadata(
                    id: id,
                    title: title,
                    createdAt: Date(),
                    sourceURL: sourceURL,
                    sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
                    audioFilename: audioURL.lastPathComponent
                ),
                to: folder.appendingPathComponent(LibraryMetadata.originalFilename)
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return SavedOriginal(
            id: id,
            title: title,
            sourceURL: sourceURL,
            sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
            audioURL: audioURL
        )
    }

    private func savedOriginal(for sourceURL: URL) throws -> SavedOriginal? {
        let root = try libraryRoot(named: "Originals")
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for folder in folders {
            let metadataURL = folder.appendingPathComponent(LibraryMetadata.originalFilename)
            guard let metadata = try? LibraryMetadata.read(
                OriginalMetadata.self,
                from: metadataURL
            ) else { continue }
            let requestedKey = YouTubeSource.canonicalKey(for: sourceURL)
            let metadataKey = metadata.sourceKey
                ?? YouTubeSource.canonicalKey(for: metadata.sourceURL)
            guard metadata.sourceURL == sourceURL
                    || (requestedKey != nil && requestedKey == metadataKey) else { continue }
            let audioURL = folder.appendingPathComponent(metadata.audioFilename)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            return SavedOriginal(
                id: metadata.id,
                title: metadata.title,
                sourceURL: metadata.sourceURL,
                sourceKey: metadataKey,
                audioURL: audioURL
            )
        }
        return nil
    }

    private func savedTrack(
        for original: SavedOriginal,
        using separationModel: SeparationModelKind
    ) throws -> LocalTrack? {
        let root = try libraryRoot(named: "Tracks")
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var matches: [(Date, LocalTrack)] = []
        for folder in folders {
            let metadataURL = folder.appendingPathComponent(LibraryMetadata.trackFilename)
            guard let metadata = try? LibraryMetadata.read(
                TrackMetadata.self,
                from: metadataURL
            ), metadata.separationModel == separationModel,
               metadata.separationCacheVersion == separationModel.separationCacheVersion,
               metadata.stems == separationModel.stems else { continue }

            let metadataKey = metadata.sourceKey
                ?? metadata.sourceURL.flatMap(YouTubeSource.canonicalKey(for:))
            let sameSource = metadata.sourceOriginalID == original.id
                || (original.sourceKey != nil && metadataKey == original.sourceKey)
            guard sameSource else { continue }

            let files: [StemKind: URL] = Dictionary(
                uniqueKeysWithValues: separationModel.stems.compactMap { stem -> (StemKind, URL)? in
                let url = folder
                    .appendingPathComponent(stem.rawValue)
                    .appendingPathExtension("wav")
                guard FileManager.default.fileExists(atPath: url.path),
                      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 0,
                      (try? AVAudioFile(forReading: url)) != nil else {
                    return nil
                }
                return (stem, url)
            })
            guard files.count == separationModel.stems.count else { continue }
            matches.append((
                metadata.createdAt,
                LocalTrack(
                    id: metadata.id,
                    title: metadata.title,
                    files: files,
                    createdAt: metadata.createdAt,
                    sourceURL: metadata.sourceURL,
                    sourceOriginalID: metadata.sourceOriginalID,
                    separationModel: metadata.separationModel
                )
            ))
        }
        return matches.max { $0.0 < $1.0 }?.1
    }

    private func libraryRoot(named name: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    private func updateEstimatedRemaining(forSeparationProgress progress: Double) {
        guard progress > 0.02, progress < 1, let separationStartedAt else {
            estimatedRemainingText = nil
            return
        }
        let elapsed = Date().timeIntervalSince(separationStartedAt)
        let remaining = elapsed * (1 - progress) / progress
        guard remaining.isFinite, remaining > 5 else {
            estimatedRemainingText = "Almost done"
            return
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        estimatedRemainingText = minutes == 1
            ? "About 1 minute remaining"
            : "About \(minutes) minutes remaining"
    }

    private func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "The download failed: \(urlError.localizedDescription). Check your connection and try again."
        }
        return error.localizedDescription
    }
}

private struct SavedOriginal: Sendable {
    let id: UUID
    let title: String
    let sourceURL: URL
    let sourceKey: String?
    let audioURL: URL
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
        case .noCompatibleAudio: "YouTube did not provide a compatible audio stream for this video."
        case .httpStatus(let code): "YouTube refused the audio download (HTTP \(code))."
        }
    }
}
