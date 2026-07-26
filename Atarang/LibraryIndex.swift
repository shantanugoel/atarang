import AVFoundation
import Foundation
import OSLog

/// Everything the Library shows, as one immutable value.
///
/// The UI never reads the file system. It reads whichever snapshot it was last
/// given, so a refresh is a single replacement rather than three collections
/// changing out from under a view mid-render.
struct LibrarySnapshot: Sendable {
    var originals: [HistoryOriginal] = []
    var tracks: [HistoryTrack] = []
    var recordings: [HistoryRecording] = []

    static let empty = LibrarySnapshot()
}

/// Reads the library off the main actor, and re-reads as little of it as it can.
///
/// The expensive parts of a refresh are not the metadata files — those are a few
/// hundred bytes each — but opening every audio file to measure its duration and
/// walking every folder to add up bytes. Those two results are cached against
/// the folder's modification date and child count, so a refresh after recording
/// one take re-measures one folder instead of the whole library.
actor LibraryIndexer {
    static let shared = LibraryIndexer()

    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Library"
    )

    /// The persistent side of the index. Losing it costs one slow refresh, so it
    /// is written best-effort and never blocks a snapshot.
    private var measurements: [String: Measurement] = [:]
    private var didLoadMeasurements = false
    private var pendingSave = false

    /// How many folders have been measured from disk rather than from the index.
    /// The incremental claim this type makes is otherwise invisible: a correct
    /// snapshot and a wastefully rebuilt one look identical from outside.
    private(set) var freshMeasurementCount = 0

    private let indexFilename = "library-index.json"
    private let rootOverride: URL?

    init(root: URL? = nil) {
        rootOverride = root
    }

    private var root: URL? {
        rootOverride ?? (try? LibraryStaging.applicationSupportRoot())
    }

    /// Rebuilds the snapshot, reusing every measurement whose folder has not
    /// changed since it was taken.
    func snapshot() async -> LibrarySnapshot {
        loadMeasurementsIfNeeded()
        var reachable: Set<String> = []
        var snapshot = LibrarySnapshot()
        snapshot.originals = discoverOriginals(reachable: &reachable)
            .sorted { $0.createdAt > $1.createdAt }
        snapshot.tracks = discoverTracks(reachable: &reachable)
            .sorted { $0.createdAt > $1.createdAt }
        snapshot.recordings = discoverRecordings(reachable: &reachable)
            .sorted { $0.createdAt > $1.createdAt }
        // Reconciliation is the other half of incremental: entries for folders
        // the user deleted must not accumulate forever in the index file.
        let stale = measurements.keys.filter { !reachable.contains($0) }
        if !stale.isEmpty {
            for key in stale { measurements[key] = nil }
            pendingSave = true
        }
        saveMeasurementsIfNeeded()
        return snapshot
    }

    /// Forgets every measurement, so the next snapshot re-reads the library from
    /// disk. For the pull-to-refresh gesture, which exists precisely for when
    /// the user believes what is on screen is wrong.
    func invalidate() {
        measurements.removeAll()
        pendingSave = true
    }

    // MARK: - Discovery

    private func discoverOriginals(reachable: inout Set<String>) -> [HistoryOriginal] {
        folders(in: "Originals").compactMap { folder in
            guard let metadata = try? LibraryMetadata.read(
                OriginalMetadata.self,
                from: folder.appendingPathComponent(LibraryMetadata.originalFilename)
            ) else { return nil }
            let audioURL = folder.appendingPathComponent(metadata.audioFilename)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { return nil }
            reachable.insert(key(for: folder))
            let measured = measure(folder, audioAt: audioURL)
            return HistoryOriginal(
                id: metadata.id,
                title: metadata.title,
                createdAt: metadata.createdAt,
                sourceURL: metadata.sourceURL,
                sourceKey: metadata.sourceKey,
                folderURL: folder,
                audioURL: audioURL,
                duration: measured.duration,
                byteCount: measured.byteCount
            )
        }
    }

    private func discoverTracks(reachable: inout Set<String>) -> [HistoryTrack] {
        folders(in: "Tracks").compactMap { folder in
            guard let metadata = try? LibraryMetadata.read(
                TrackMetadata.self,
                from: folder.appendingPathComponent(LibraryMetadata.trackFilename)
            ) else { return nil }
            let files = Dictionary(uniqueKeysWithValues: metadata.stems.compactMap { stem -> (StemKind, URL)? in
                let url = folder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
                return FileManager.default.fileExists(atPath: url.path) ? (stem, url) : nil
            })
            guard files.count == metadata.stems.count else { return nil }
            reachable.insert(key(for: folder))
            let measured = measure(folder, audioAt: files[.vocals] ?? files.values.first)
            return HistoryTrack(
                id: metadata.id,
                title: metadata.title,
                createdAt: metadata.createdAt,
                sourceURL: metadata.sourceURL,
                sourceKey: metadata.sourceKey,
                sourceOriginalID: metadata.sourceOriginalID,
                separationModel: metadata.separationModel,
                separationCacheVersion: metadata.separationCacheVersion,
                folderURL: folder,
                files: files,
                duration: measured.duration,
                byteCount: measured.byteCount
            )
        }
    }

    private func discoverRecordings(reachable: inout Set<String>) -> [HistoryRecording] {
        folders(in: "Recordings").compactMap { folder in
            guard let metadata = try? LibraryMetadata.read(
                RecordingMetadata.self,
                from: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
            ) else { return nil }
            let exported = exportedAudio(in: folder, preferredName: metadata.exportedFilename)
            let microphone = folder.appendingPathComponent("microphone.caf")
            let backing = folder.appendingPathComponent("backing.caf")
            let microphoneExists = FileManager.default.fileExists(atPath: microphone.path)
            let backingExists = FileManager.default.fileExists(atPath: backing.path)
            guard exported != nil || microphoneExists else { return nil }
            reachable.insert(key(for: folder))
            // A recording's duration is recorded when the take is committed, so
            // there is nothing to measure but its size.
            let measured = measure(folder, audioAt: nil)
            return HistoryRecording(
                id: metadata.id,
                title: metadata.title,
                createdAt: metadata.createdAt,
                duration: metadata.duration,
                sourceTrackID: metadata.sourceTrackID,
                folderURL: folder,
                microphoneURL: microphoneExists ? microphone : nil,
                backingURL: backingExists ? backing : nil,
                microphoneLevel: metadata.microphoneLevel ?? 1,
                backingLevel: metadata.backingLevel ?? 0.7,
                playbackURL: exported,
                byteCount: measured.byteCount
            )
        }
    }

    private func folders(in rootName: String) -> [URL] {
        guard let directory = root?.appendingPathComponent(rootName, isDirectory: true),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
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

    // MARK: - Measurement cache

    private struct Measurement: Codable, Sendable {
        var duration: TimeInterval
        var byteCount: Int64
        /// What the folder looked like when the measurement was taken. Library
        /// folders are only ever published, replaced, or added to as a whole, and
        /// each of those changes the directory's own modification date.
        ///
        /// Held as an interval rather than a `Date` because the index is written
        /// with the app's ISO-8601 date strategy, which rounds to the second. A
        /// rounded timestamp never matches the modification date it came from, so
        /// a reloaded index would remeasure the entire library — and a folder
        /// changed within the same second as its measurement would be missed.
        var modifiedAt: TimeInterval
        var childCount: Int
    }

    private func key(for folder: URL) -> String {
        "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent)"
    }

    private func measure(_ folder: URL, audioAt audioURL: URL?) -> Measurement {
        let fingerprint = fingerprint(of: folder)
        let cacheKey = key(for: folder)
        if let cached = measurements[cacheKey],
           cached.modifiedAt == fingerprint.modifiedAt,
           cached.childCount == fingerprint.childCount {
            return cached
        }
        let measurement = Measurement(
            duration: audioURL.flatMap { LibraryStaging.audioDuration(at: $0) } ?? 0,
            byteCount: LibraryStaging.byteCount(of: folder),
            modifiedAt: fingerprint.modifiedAt,
            childCount: fingerprint.childCount
        )
        measurements[cacheKey] = measurement
        freshMeasurementCount += 1
        pendingSave = true
        return measurement
    }

    private func fingerprint(of folder: URL) -> (modifiedAt: TimeInterval, childCount: Int) {
        let modifiedAt = (try? folder.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
        let childCount = (try? FileManager.default.contentsOfDirectory(
            atPath: folder.path
        ).count) ?? 0
        return (modifiedAt.timeIntervalSinceReferenceDate, childCount)
    }

    private var indexURL: URL? {
        root?.appendingPathComponent(indexFilename)
    }

    private func loadMeasurementsIfNeeded() {
        guard !didLoadMeasurements else { return }
        didLoadMeasurements = true
        guard let indexURL,
              let stored = try? LibraryMetadata.read(
                [String: Measurement].self,
                from: indexURL
              ) else { return }
        measurements = stored
    }

    private func saveMeasurementsIfNeeded() {
        guard pendingSave, let indexURL else { return }
        pendingSave = false
        do {
            // `LibraryMetadata.write` is atomic, so a process killed mid-write
            // leaves the previous index rather than a truncated one.
            try LibraryMetadata.write(measurements, to: indexURL)
        } catch {
            logger.error(
                "Could not save the library index: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

extension LibrarySnapshot {
    /// The saved separation for this source, in this style, or `nil`.
    ///
    /// Studio used to answer this by scanning `Tracks/` on every keystroke.
    /// Answering from the snapshot means the offer Studio makes and the item the
    /// Library lists are the same fact, and typing a URL touches no files at all.
    func separation(
        forSourceURL sourceURL: URL,
        using separationModel: SeparationModelKind
    ) -> LocalTrack? {
        let key = YouTubeSource.canonicalKey(for: sourceURL)
        guard let originalID = originals.first(where: {
            $0.sourceURL == sourceURL || (key != nil && $0.sourceKey == key)
        })?.id else { return nil }
        return tracks
            .filter {
                $0.separationModel == separationModel
                    && $0.separationCacheVersion == separationModel.separationCacheVersion
                    && Set($0.files.keys) == Set(separationModel.stems)
                    && ($0.sourceOriginalID == originalID
                        || (key != nil && $0.sourceKey == key))
            }
            .max { $0.createdAt < $1.createdAt }?
            .localTrack
    }

    /// Which styles this source has already been separated with.
    func separationModels(forSourceURL sourceURL: URL) -> [SeparationModelKind] {
        SeparationModelKind.allCases.filter {
            separation(forSourceURL: sourceURL, using: $0) != nil
        }
    }
}
