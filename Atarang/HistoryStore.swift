import Combine
import Foundation

struct HistoryOriginal: Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    /// `nil` once the metadata has been reconstructed without a known source.
    let sourceURL: URL?
    let sourceKey: String?
    let folderURL: URL
    /// `nil` when the downloaded audio has been evicted to reclaim space. The
    /// entry stays in the Library because the folder still holds the user's own
    /// work — practice settings, loops, corrections — which is not cache and is
    /// not regenerable. Only the audio is.
    let audioURL: URL?
    let duration: TimeInterval
    let byteCount: Int64
    /// Practice state and analysis results stored beside this song, in bytes.
    /// Part of `byteCount`, reported separately for storage accounting.
    let songDataByteCount: Int64

    /// Whether the audio is gone but the song is still here. Re-separating
    /// downloads it again, which is only possible while the source is known.
    var isEvicted: Bool { audioURL == nil }
    var canRedownload: Bool { sourceURL != nil }
}

struct HistoryTrack: Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let sourceURL: URL?
    let sourceKey: String?
    let sourceOriginalID: UUID?
    let separationModel: SeparationModelKind
    let separationCacheVersion: Int
    let folderURL: URL
    let files: [StemKind: URL]
    let duration: TimeInterval
    let byteCount: Int64
    /// Only non-zero when the original this came from has been deleted and the
    /// song's state fell back to living here.
    let songDataByteCount: Int64

    var localTrack: LocalTrack {
        LocalTrack(
            id: id,
            title: title,
            files: files,
            createdAt: createdAt,
            sourceURL: sourceURL,
            sourceOriginalID: sourceOriginalID,
            separationModel: separationModel,
            folderURL: folderURL
        )
    }
}

struct HistoryRecording: Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let duration: TimeInterval
    let sourceTrackID: UUID?
    let folderURL: URL
    let microphoneURL: URL?
    let backingURL: URL?
    let microphoneLevel: Float
    let backingLevel: Float
    let playbackURL: URL?
    let byteCount: Int64

    var canEditMix: Bool {
        microphoneURL != nil && backingURL != nil
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    /// One published value for the whole library, so one change to the data
    /// produces one change to the interface.
    @Published private(set) var snapshot = LibrarySnapshot.empty
    @Published var errorMessage: String?

    var originals: [HistoryOriginal] { snapshot.originals }
    var tracks: [HistoryTrack] { snapshot.tracks }
    var recordings: [HistoryRecording] { snapshot.recordings }

    private var refreshTask: Task<Void, Never>?
    private var needsAnotherPass = false
    private var refreshSubscription: AnyCancellable?

    init() {
        // Every writer in the app announces its change the same way, and a
        // single separation can announce twice — once for the saved original,
        // once for the finished stems. Listening here, in one place, means the
        // coalescing below applies to all of them.
        refreshSubscription = NotificationCenter.default
            .publisher(for: .atarangLibraryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        refresh()
    }

    /// Asks for a fresh snapshot. Concurrent asks collapse into at most one
    /// extra pass, so a burst of notifications cannot start a queue of scans.
    func refresh() {
        guard refreshTask == nil else {
            needsAnotherPass = true
            return
        }
        refreshTask = Task { @MainActor [weak self] in
            defer { self?.refreshTask = nil }
            repeat {
                self?.needsAnotherPass = false
                let next = await LibraryIndexer.shared.snapshot()
                self?.snapshot = next
            } while self?.needsAnotherPass == true
        }
    }

    /// Rebuilds the snapshot and waits for it.
    ///
    /// `refresh()` is fire-and-forget, which is right for a notification and
    /// wrong for a caller that is about to *measure* the library: it would read
    /// the totals from before its own change. Storage settings uses this.
    func refreshNow() async {
        snapshot = await LibraryIndexer.shared.snapshot()
    }

    /// A user-initiated refresh distrusts the cached measurements as well as the
    /// snapshot, because that is what the gesture is for.
    func reload() {
        Task {
            await LibraryIndexer.shared.invalidate()
            refresh()
        }
    }

    func track(withID id: UUID) -> HistoryTrack? {
        tracks.first { $0.id == id }
    }

    func original(withID id: UUID) -> HistoryOriginal? {
        originals.first { $0.id == id }
    }

    func delete(original: HistoryOriginal) {
        delete(folder: original.folderURL)
    }

    func delete(originals: [HistoryOriginal]) {
        delete(folders: originals.map(\.folderURL))
    }

    func delete(track: HistoryTrack) {
        delete(folder: track.folderURL)
    }

    func delete(tracks: [HistoryTrack]) {
        delete(folders: tracks.map(\.folderURL))
    }

    func delete(recording: HistoryRecording) {
        delete(folder: recording.folderURL)
    }

    func delete(recordings: [HistoryRecording]) {
        delete(folders: recordings.map(\.folderURL))
    }

    func saveMix(
        recording: HistoryRecording,
        microphoneLevel: Float,
        backingLevel: Float,
        asNew: Bool
    ) async throws {
        guard let sourceMicrophoneURL = recording.microphoneURL,
              let sourceBackingURL = recording.backingURL else {
            throw HistoryStoreError.missingRawAudio
        }

        // A new mix is built in a staging folder and renamed into place once
        // its audio, export, and metadata are all present, so a failure part
        // way through leaves no half-formed performance in the Library.
        let workingFolder: URL
        let destinationFolder: URL
        let destinationMicrophoneURL: URL
        let destinationBackingURL: URL
        let id: UUID
        let title: String
        let createdAt: Date

        if asNew {
            id = UUID()
            let root = try LibraryStaging.libraryRoot(named: "Recordings")
            workingFolder = try LibraryStaging.makeDirectory(in: root)
            destinationFolder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            destinationMicrophoneURL = workingFolder.appendingPathComponent("microphone.caf")
            destinationBackingURL = workingFolder.appendingPathComponent("backing.caf")
            do {
                try FileManager.default.copyItem(at: sourceMicrophoneURL, to: destinationMicrophoneURL)
                try FileManager.default.copyItem(at: sourceBackingURL, to: destinationBackingURL)
            } catch {
                LibraryStaging.discard(workingFolder)
                throw error
            }
            title = nextMixTitle(for: recording.title)
            createdAt = Date()
        } else {
            id = recording.id
            workingFolder = recording.folderURL
            destinationFolder = recording.folderURL
            destinationMicrophoneURL = sourceMicrophoneURL
            destinationBackingURL = sourceBackingURL
            title = recording.title
            createdAt = recording.createdAt
        }

        let take = RecordedTake(
            id: id,
            title: title,
            microphoneURL: destinationMicrophoneURL,
            backingURL: destinationBackingURL,
            microphoneLevel: min(2, max(0, microphoneLevel)),
            backingLevel: min(1, max(0, backingLevel)),
            duration: recording.duration,
            createdAt: createdAt
        )

        do {
            // Same serial lane as Studio's exports, so re-mixing a take in the
            // Library cannot run a second encoder alongside one that is still
            // finishing.
            let exportedURL = try await RecordingExportCenter.shared.exportSerially(take)
            let metadata = RecordingMetadata(
                id: id,
                title: title,
                createdAt: createdAt,
                duration: recording.duration,
                sourceTrackID: recording.sourceTrackID,
                microphoneLevel: take.microphoneLevel,
                backingLevel: take.backingLevel,
                exportedFilename: exportedURL.lastPathComponent
            )
            guard LibraryStaging.audioDuration(at: exportedURL) != nil else {
                throw HistoryStoreError.unreadableExport
            }
            try LibraryMetadata.write(
                metadata,
                to: workingFolder.appendingPathComponent(LibraryMetadata.recordingFilename)
            )
            SongStorage.applyBackupPolicy(toRecording: workingFolder)
            if asNew {
                try LibraryStaging.commit(workingFolder, to: destinationFolder)
            }
        } catch {
            if asNew { LibraryStaging.discard(workingFolder) }
            throw error
        }

        refresh()
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
    }

    private func delete(folder: URL) {
        delete(folders: [folder])
    }

    private func delete(folders: [URL]) {
        guard !folders.isEmpty else { return }
        var firstError: Error?
        for folder in folders {
            do {
                try FileManager.default.removeItem(at: folder)
            } catch {
                firstError = firstError ?? error
            }
        }
        refresh()
        if let firstError {
            errorMessage = "Some items could not be deleted: \(firstError.localizedDescription)"
        }
    }

    private func nextMixTitle(for title: String) -> String {
        let base = title.replacingOccurrences(
            of: #" Mix(?: \d+)?$"#,
            with: "",
            options: .regularExpression
        )
        let existing = Set(recordings.map(\.title))
        let first = "\(base) Mix"
        guard existing.contains(first) else { return first }
        var number = 2
        while existing.contains("\(base) Mix \(number)") { number += 1 }
        return "\(base) Mix \(number)"
    }
}

private enum HistoryStoreError: LocalizedError {
    case missingRawAudio
    case unreadableExport

    var errorDescription: String? {
        switch self {
        case .missingRawAudio:
            "The original microphone and backing audio are needed to edit this mix."
        case .unreadableExport:
            "The new mix could not be read back after it was written, so it was discarded."
        }
    }
}
