import AVFoundation
import Combine
import Foundation

struct HistoryTrack: Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let sourceURL: URL?
    let separationModel: SeparationModelKind
    let folderURL: URL
    let files: [StemKind: URL]
    let duration: TimeInterval
    let byteCount: Int64

    var localTrack: LocalTrack {
        LocalTrack(
            id: id,
            title: title,
            files: files,
            createdAt: createdAt,
            sourceURL: sourceURL,
            separationModel: separationModel
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
    let playbackURL: URL?
    let byteCount: Int64
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var tracks: [HistoryTrack] = []
    @Published private(set) var recordings: [HistoryRecording] = []
    @Published var errorMessage: String?

    init() { refresh() }

    func refresh() {
        do {
            tracks = try discoverTracks().sorted { $0.createdAt > $1.createdAt }
            recordings = try discoverRecordings().sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = "History could not be refreshed: \(error.localizedDescription)"
        }
    }

    func track(withID id: UUID) -> HistoryTrack? {
        tracks.first { $0.id == id }
    }

    func delete(track: HistoryTrack) {
        delete(folder: track.folderURL)
    }

    func delete(recording: HistoryRecording) {
        delete(folder: recording.folderURL)
    }

    private func delete(folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
            refresh()
        } catch {
            errorMessage = "This item could not be deleted: \(error.localizedDescription)"
        }
    }

    private func discoverTracks() throws -> [HistoryTrack] {
        let root = try libraryRoot(named: "Tracks", create: true)
        return try folders(in: root).compactMap { folder in
            let metadataURL = folder.appendingPathComponent(LibraryMetadata.trackFilename)
            let metadata = try? LibraryMetadata.read(TrackMetadata.self, from: metadataURL)
            let separationModel = metadata?.separationModel ?? .htdemucs
            let expectedStems = metadata?.stems ?? separationModel.stems
            let files = Dictionary(uniqueKeysWithValues: expectedStems.compactMap { stem in
                let url = folder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
                return FileManager.default.fileExists(atPath: url.path) ? (stem, url) : nil
            })
            guard files.count == expectedStems.count else { return nil }
            let fallbackDate = createdAt(for: folder)
            let id = metadata?.id ?? UUID(uuidString: folder.lastPathComponent) ?? UUID()
            return HistoryTrack(
                id: id,
                title: metadata?.title ?? "Separated track",
                createdAt: metadata?.createdAt ?? fallbackDate,
                sourceURL: metadata?.sourceURL,
                separationModel: separationModel,
                folderURL: folder,
                files: files,
                duration: audioDuration(at: files[.vocals] ?? files.values.first),
                byteCount: folderSize(folder)
            )
        }
    }

    private func discoverRecordings() throws -> [HistoryRecording] {
        let root = try libraryRoot(named: "Recordings", create: true)
        return try folders(in: root).compactMap { folder in
            let metadataURL = folder.appendingPathComponent(LibraryMetadata.recordingFilename)
            let metadata = try? LibraryMetadata.read(RecordingMetadata.self, from: metadataURL)
            let exported = exportedAudio(in: folder, preferredName: metadata?.exportedFilename)
            let microphone = folder.appendingPathComponent("microphone.caf")
            guard exported != nil || FileManager.default.fileExists(atPath: microphone.path) else { return nil }
            let fallbackDate = createdAt(for: folder)
            let id = metadata?.id ?? UUID(uuidString: folder.lastPathComponent) ?? UUID()
            return HistoryRecording(
                id: id,
                title: metadata?.title ?? "Recorded performance",
                createdAt: metadata?.createdAt ?? fallbackDate,
                duration: metadata?.duration ?? audioDuration(at: exported ?? microphone),
                sourceTrackID: metadata?.sourceTrackID,
                folderURL: folder,
                playbackURL: exported,
                byteCount: folderSize(folder)
            )
        }
    }

    private func libraryRoot(named name: String, create: Bool) throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        ).appendingPathComponent(name, isDirectory: true)
    }

    private func folders(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func createdAt(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    private func exportedAudio(in folder: URL, preferredName: String?) -> URL? {
        if let preferredName {
            let preferred = folder.appendingPathComponent(preferredName)
            if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents?.first { $0.pathExtension.lowercased() == "m4a" }
    }

    private func audioDuration(at url: URL?) -> TimeInterval {
        guard let url, let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
