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
    @Published var errorMessage: String?

    /// The separation the import screen offers by default.
    ///
    /// This used to reset to `.htdemucs` on every launch, which meant anyone who
    /// preferred the 6-stem or a vocals-only split re-chose it every session. It
    /// is a real preference now, editable in Settings and saved here so both
    /// screens read one value.
    @Published var selectedModel: SeparationModelKind {
        didSet {
            guard selectedModel != oldValue else { return }
            UserDefaults.standard.set(
                selectedModel.rawValue,
                forKey: Self.defaultModelDefaultsKey
            )
        }
    }

    static let defaultModelDefaultsKey = "defaultSeparationModel"
    private let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "Separation")

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultModelDefaultsKey)
            .flatMap(SeparationModelKind.init(rawValue:))
        // A saved choice the current device cannot run is not a choice.
        if let saved, saved.isAvailableOnCurrentDevice {
            selectedModel = saved
        } else {
            selectedModel = .recommendedForCurrentDevice
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
        let separationModel = selectedModel
        guard separationModel.isAvailableOnCurrentDevice else {
            errorMessage = separationModel.unavailabilityMessage
            return nil
        }
        return await runSeparationJob(
            title: url.absoluteString,
            requiredMemoryBytes: separationModel.minimumAvailableMemoryBytes
        ) { context in
            try await self.separate(
                url: url,
                using: separationModel,
                force: force,
                context: context
            )
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
        selectedModel = separationModel
        let savedOriginal = SavedOriginal(
            id: original.id,
            title: original.title,
            sourceURL: original.sourceURL,
            sourceKey: original.sourceKey
                ?? YouTubeSource.canonicalKey(for: original.sourceURL),
            audioURL: original.audioURL
        )
        return await runSeparationJob(
            title: original.title,
            requiredMemoryBytes: separationModel.minimumAvailableMemoryBytes
        ) { context in
            try await self.separate(
                original: savedOriginal,
                using: separationModel,
                force: force,
                context: context
            )
        }
    }

    /// Every separation goes through the shared queue, so it cannot run beside
    /// another job or during a take, and its progress is reported in the one
    /// place the UI reads. A cancelled job returns `nil` without an error,
    /// because the user stopping the work is not a failure.
    private func runSeparationJob(
        title: String,
        requiredMemoryBytes: UInt64?,
        work: @escaping @Sendable (AnalysisJobContext) async throws -> SeparationResult
    ) async -> SeparationResult? {
        do {
            return try await AnalysisQueue.shared.submit(
                kind: .separation,
                title: title,
                requiredMemoryBytes: requiredMemoryBytes,
                work: work
            ).value
        } catch {
            logger.error("Separation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = friendlyMessage(for: error)
            return nil
        }
    }

    private func separate(
        original: SavedOriginal,
        using separationModel: SeparationModelKind,
        force: Bool,
        context: AnalysisJobContext
    ) async throws -> SeparationResult {
        context.report("Using saved original…", progress: 0.17)
        if !force, let existing = try savedTrack(
            for: original,
            using: separationModel
        ) {
            context.report("Opened saved separation", progress: 1)
            return .reused(existing)
        }
        return .created(
            try await separate(
                original: original,
                using: separationModel,
                context: context
            )
        )
    }

    private func separate(
        url: URL,
        using separationModel: SeparationModelKind,
        force: Bool,
        context: AnalysisJobContext
    ) async throws -> SeparationResult {
        context.report("Reading video information…", progress: 0.01)
        try Task.checkCancellation()
        let original: SavedOriginal
        if let existing = try savedOriginal(for: url) {
            original = existing
            context.report("Using saved original…", progress: 0.17)
        } else {
            context.report("Preparing bundled yt-dlp…", progress: 0.05)
            try await BundledYTDLP.shared.install()
            context.report("Reading video information…", progress: 0.09)
            logger.info("Starting extraction for \(url.absoluteString, privacy: .public) with bundled yt-dlp \(BundledYTDLP.version, privacy: .public)")

            let slowNotice = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                context.report(
                    "YouTube is taking longer than expected…",
                    progress: 0.11
                )
            }
            defer { slowNotice.cancel() }
            let downloaded = try await downloadAudio(from: url, context: context)
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
            context.report("Opened saved separation", progress: 1)
            return .reused(existing)
        }
        return .created(
            try await separate(
                original: original,
                using: separationModel,
                context: context
            )
        )
    }

    private func separate(
        original: SavedOriginal,
        using separationModel: SeparationModelKind,
        context: AnalysisJobContext
    ) async throws -> LocalTrack {
        let availableMemory = ModelMemoryBudget.availableBytes
        logger.info(
            "Available memory before \(separationModel.title, privacy: .public): \(availableMemory, privacy: .public) bytes"
        )
        guard separationModel.isAvailableOnCurrentDevice else {
            throw StemSeparatorError.modelUnavailable(separationModel)
        }
        context.report(
            separationModel == .htdemucs
                ? "Loading \(separationModel.title)…"
                : "Preparing \(separationModel.title)…",
            progress: 0.17
        )
        let artifact = try await ModelAssetStore.shared.artifact(
            for: separationModel
        ) { status, value in
            context.report(status, progress: value)
        }
        context.report(
            "Loading on-device \(separationModel.title)…",
            progress: 0.18
        )
        let separator = try StemSeparator(
            modelKind: separationModel,
            artifact: artifact
        )
        try Task.checkCancellation()
        // Stems are generated into a hidden staging folder. `Tracks/<id>` only
        // ever comes into existence complete: every expected stem present,
        // readable, and described by a metadata file written before the commit.
        let output = try makeTrackStaging()
        let stagedFiles: [StemKind: URL]
        do {
            stagedFiles = try await separator.separate(
                fileURL: original.audioURL,
                outputFolder: output.staging
            ) { value in
                Task { @MainActor in
                    context.report(
                        "Separating \(separationModel.stems.count) stems on this device…",
                        progress: 0.2 + value * 0.78,
                        // The estimate is timed against inference alone. Timing
                        // it against overall progress would count the download
                        // and model load as separation and finish early.
                        estimateFraction: value
                    )
                }
            }
        } catch {
            LibraryStaging.discard(output.staging)
            throw error
        }

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
        let files: [StemKind: URL]
        do {
            try validateStagedStems(stagedFiles, expecting: separationModel.stems)
            try LibraryMetadata.write(
                metadata,
                to: output.staging.appendingPathComponent(LibraryMetadata.trackFilename)
            )
            try LibraryStaging.commit(output.staging, to: output.destination)
            files = stagedFiles.mapValues {
                output.destination.appendingPathComponent($0.lastPathComponent)
            }
        } catch {
            LibraryStaging.discard(output.staging)
            throw error
        }

        context.report("Ready to mix", progress: 1)
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
        logger.info("Separation completed successfully")
        return LocalTrack(
            id: output.id,
            title: original.title,
            files: files,
            createdAt: createdAt,
            sourceURL: original.sourceURL,
            sourceOriginalID: original.id,
            separationModel: separationModel,
            folderURL: output.destination
        )
    }

    /// A separation is publishable only when every stem the model promises is
    /// present, non-empty, and openable as audio.
    private func validateStagedStems(
        _ files: [StemKind: URL],
        expecting stems: [StemKind]
    ) throws {
        for stem in stems {
            guard let url = files[stem] else {
                throw SeparationFailure.incompleteOutput(stem)
            }
            guard LibraryStaging.audioDuration(at: url) != nil else {
                throw SeparationFailure.unreadableStem(stem)
            }
        }
    }

    /// Extraction and download, both cancellable.
    ///
    /// Neither used to be: extraction ran inside a `Task.detached`, which
    /// inherits no cancellation, and the download was never asked to stop. Both
    /// are now ordinary awaits in the job's own task, so cancelling the job ends
    /// them at the next suspension point and the scratch folder goes with them
    /// rather than being left in the temporary directory.
    private func downloadAudio(
        from url: URL,
        context: AnalysisJobContext
    ) async throws -> (url: URL, title: String) {
        context.report("Reading YouTube video information…", progress: 0.11)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Atarang-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        do {
            let metadataURL = folder.appendingPathComponent("selection.json")
            let printTemplate = "{\"title\":%(title)j,\"url\":%(url)j,\"headers\":%(http_headers)j,\"size\":%(filesize)j}"

            // `BundledYTDLP` is an actor, so the interpreter already runs off the
            // main actor without a detached task standing between this job and
            // its cancellation.
            try await BundledYTDLP.shared.run(argv: [
                "--no-playlist",
                "--no-check-certificates",
                "--no-warnings",
                "--skip-download",
                "--format", "bestaudio[ext=m4a]",
                "--print-to-file", printTemplate, metadataURL.path,
                url.absoluteString,
            ])
            try Task.checkCancellation()
            let selection = try JSONDecoder().decode(
                YTDLPSelection.self,
                from: try Data(contentsOf: metadataURL)
            )

            guard let mediaURL = URL(string: selection.url) else {
                throw SeparationFailure.noCompatibleAudio
            }
            context.report("Downloading audio to this device…", progress: 0.14)
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
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent("source.m4a")
            try FileManager.default.moveItem(at: temporary, to: destination)
            context.report("Downloaded", progress: 0.17)
            return (destination, selection.title)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func makeTrackStaging() throws -> (id: UUID, staging: URL, destination: URL) {
        let root = try LibraryStaging.libraryRoot(named: "Tracks")
        let id = UUID()
        return (
            id,
            try LibraryStaging.makeDirectory(in: root),
            root.appendingPathComponent(id.uuidString, isDirectory: true)
        )
    }

    private func persistOriginal(
        downloadedURL: URL,
        title: String,
        sourceURL: URL
    ) throws -> SavedOriginal {
        let root = try LibraryStaging.libraryRoot(named: "Originals")
        let id = UUID()
        let staging = try LibraryStaging.makeDirectory(in: root)
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let stagedAudioURL = staging.appendingPathComponent("source.m4a")
        do {
            try FileManager.default.moveItem(at: downloadedURL, to: stagedAudioURL)
            // Audio that will not open is not an original, however successful
            // the download looked.
            guard LibraryStaging.audioDuration(at: stagedAudioURL) != nil else {
                throw SeparationFailure.unreadableDownload
            }
            try LibraryMetadata.write(
                OriginalMetadata(
                    id: id,
                    title: title,
                    createdAt: Date(),
                    sourceURL: sourceURL,
                    sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
                    audioFilename: stagedAudioURL.lastPathComponent
                ),
                to: staging.appendingPathComponent(LibraryMetadata.originalFilename)
            )
            // Applied while staging, so the committed folder is never briefly
            // in the wrong backup state.
            SongStorage.applyBackupPolicy(
                to: staging,
                audioFilename: stagedAudioURL.lastPathComponent
            )
            try LibraryStaging.commit(staging, to: folder)
        } catch {
            LibraryStaging.discard(staging)
            throw error
        }
        return SavedOriginal(
            id: id,
            title: title,
            sourceURL: sourceURL,
            sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
            audioURL: folder.appendingPathComponent(stagedAudioURL.lastPathComponent)
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
                    separationModel: metadata.separationModel,
                    folderURL: folder
                )
            ))
        }
        return matches.max { $0.0 < $1.0 }?.1
    }

    private func libraryRoot(named name: String) throws -> URL {
        try LibraryStaging.libraryRoot(named: name)
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

private struct SavedOriginal: Sendable {
    let id: UUID
    let title: String
    let sourceURL: URL
    let sourceKey: String?
    let audioURL: URL
}

private struct YTDLPSelection: Decodable, Sendable {
    let title: String
    let url: String
    let headers: [String: String]
    let size: Int?
}

private enum SeparationFailure: LocalizedError {
    case noCompatibleAudio
    case httpStatus(Int)
    case unreadableDownload
    case incompleteOutput(StemKind)
    case unreadableStem(StemKind)

    var errorDescription: String? {
        switch self {
        case .noCompatibleAudio: "YouTube did not provide a compatible audio stream for this video."
        case .httpStatus(let code): "YouTube refused the audio download (HTTP \(code))."
        case .unreadableDownload: "The downloaded audio could not be read back, so it was discarded."
        case .incompleteOutput(let stem): "Separation did not produce the \(stem.title.lowercased()) stem."
        case .unreadableStem(let stem): "The separated \(stem.title.lowercased()) stem could not be read back."
        }
    }
}
