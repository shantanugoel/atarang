import Foundation
import OSLog

/// Whether there is room to do something before it is started.
///
/// Everything expensive in this app writes hundreds of megabytes: a four-minute
/// 4-stem separation is about 340 MB of float WAV, a take is about 33 MB a
/// minute, and an optional model is 40–136 MB downloaded plus its staging. Any
/// of them can fill the volume, and the failure that produces is the worst kind
/// — several minutes of work, no result, and an error from `NSFileManager` that
/// names a temporary path instead of saying the disk is full.
///
/// So the check happens first, before the work starts, and the copy says how
/// much more room is needed rather than that something went wrong.
enum StorageCapacity {
    /// Room the app will not spend, whatever it is asked to do.
    ///
    /// iOS misbehaves well before a volume actually reaches zero — no space for
    /// its own caches, none to install anything — and a separation that fills
    /// the disk on its final chunk has wasted the whole run. Holding a reserve
    /// back means the failure lands on our check with an explanation rather
    /// than on the system with a path.
    static let reserveBytes: Int64 = 300_000_000

    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Storage"
    )

    /// What the system will actually give us for something the user asked for.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is larger than raw free space
    /// because it counts what iOS is willing to purge, which is the number that
    /// matters for a download the user is waiting on. It falls back to plain
    /// free capacity on the rare volume that will not report it.
    static func availableBytes(at url: URL? = nil) -> Int64 {
        let target = url ?? (try? LibraryStaging.applicationSupportRoot())
        guard let target,
              let values = try? target.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
              ]) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    /// What an operation is for, in the words the failure will use.
    enum Operation: Sendable {
        case download
        case separation(stemCount: Int)
        case modelDownload(SeparationModelKind)
        case recording
        case export
        case analysis

        var description: String {
            switch self {
            case .download: "download this song"
            case .separation: "separate this song"
            case .modelDownload(let model): "download \(model.outcomeTitle)"
            case .recording: "record this take"
            case .export: "export this performance"
            case .analysis: "save this analysis"
            }
        }

        /// What the user can do about it, when there is something specific.
        var advice: String? {
            switch self {
            case .separation:
                "Separated stems are the largest thing Atarang stores. Deleting separations you have finished with frees the most space."
            case .modelDownload:
                "Optional models can be removed again from Settings once you are done with them."
            case .download, .recording, .export, .analysis:
                nil
            }
        }
    }

    /// Checks that an operation can complete, and refuses it if it cannot.
    ///
    /// `availableBytes` is injectable because a test cannot make a volume full,
    /// and because the simulator's disk is the Mac's — a real reading there
    /// says nothing about what an iPhone would do.
    static func require(
        _ bytes: Int64,
        for operation: Operation,
        availableBytes available: Int64 = availableBytes()
    ) throws {
        let needed = bytes + reserveBytes
        guard available < needed else { return }
        logger.error(
            "Refused to \(operation.description, privacy: .public): needs \(needed, privacy: .public) bytes, \(available, privacy: .public) available"
        )
        throw StorageCapacityError.insufficient(
            operation: operation,
            requiredBytes: bytes,
            shortfallBytes: max(0, needed - available)
        )
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

/// A refusal, not a failure. The distinction matters in the copy: nothing went
/// wrong, there is simply not enough room, and the number that helps is how
/// much more is needed rather than how much is there.
enum StorageCapacityError: LocalizedError {
    case insufficient(
        operation: StorageCapacity.Operation,
        requiredBytes: Int64,
        shortfallBytes: Int64
    )

    var errorDescription: String? {
        switch self {
        case .insufficient(let operation, let required, let shortfall):
            var message = "There is not enough free space to \(operation.description). "
                + "It needs about \(StorageCapacity.formatted(required)), "
                + "so free up about \(StorageCapacity.formatted(shortfall)) and try again."
            if let advice = operation.advice { message += " " + advice }
            return message
        }
    }
}

/// How much room each kind of work takes, measured from what the app actually
/// writes rather than guessed.
///
/// Every figure here is deliberately generous. Refusing a job that would just
/// have fitted costs the user one cleanup; accepting one that does not fit
/// costs them the whole run.
enum StorageEstimate {
    /// Separated stems are 32-bit float stereo WAV at 44.1 kHz, which is what
    /// `StemSeparator` writes: 352,800 bytes of file per second of audio, per
    /// stem. A four-minute 4-stem separation is therefore about 340 MB, and a
    /// 6-stem one about 508 MB.
    static let stemBytesPerSecond: Int64 = 352_800

    /// Both recording streams together: the microphone at mono float32 and the
    /// backing mix at stereo float32, plus the M4A the take is exported to.
    static let recordingBytesPerSecond: Int64 = 560_000

    /// AAC at the export bitrate, with room for the container.
    static let exportBytesPerSecond: Int64 = 24_000

    /// A downloaded original is compressed audio; yt-dlp usually tells us the
    /// exact size, and this stands in when it does not.
    static let downloadBytesPerSecond: Int64 = 20_000

    static func separation(duration: TimeInterval, stemCount: Int) -> Int64 {
        Int64(max(0, duration).rounded()) * stemBytesPerSecond * Int64(max(1, stemCount))
    }

    /// A download of unknown size. The ten-minute floor is there because the
    /// duration is not known until after the download either — this is the
    /// estimate for the one moment the app knows least.
    static func download(duration: TimeInterval?) -> Int64 {
        let seconds = Int64(max(600, duration ?? 600).rounded())
        return seconds * downloadBytesPerSecond
    }

    /// A take runs at most as long as the song, plus its export.
    static func recording(duration: TimeInterval) -> Int64 {
        Int64(max(60, duration).rounded()) * (recordingBytesPerSecond + exportBytesPerSecond)
    }

    static func export(duration: TimeInterval) -> Int64 {
        Int64(max(60, duration).rounded()) * exportBytesPerSecond
    }

    /// Analysis results are JSON — a chord chart for a long song is tens of
    /// kilobytes. The check exists so that writing one on a full disk fails
    /// with an explanation rather than corrupting nothing in particular.
    static let analysis: Int64 = 4_000_000
}

extension SeparationModelKind {
    /// What the download itself costs, in bytes, matching `downloadSize`.
    var downloadByteCount: Int64? {
        switch self {
        case .htdemucs: nil
        case .htdemucs6s: 136_000_000
        case .mdx23cInstVocHQ: 40_000_000
        case .kimVocals: 67_000_000
        }
    }

    /// What must be free to *install* it, which is more than the download.
    ///
    /// MDX23C arrives as a zip that is extracted and then compiled by Core ML,
    /// so the archive, the extracted package, and the compiled model all exist
    /// at once. The ONNX models are moved into place and cost their size once.
    var installFootprintBytes: Int64? {
        guard let downloadByteCount else { return nil }
        switch self {
        case .mdx23cInstVocHQ: return downloadByteCount * 4
        default: return downloadByteCount * 2
        }
    }
}

/// Downloaded originals are reproducible cache.
///
/// They can be fetched again from the URL they came from, which is what makes
/// them safe to evict and safe to keep out of iCloud backup. What is *not*
/// cache is everything else in the folder — practice settings, loops, a
/// corrected chord chart — so eviction removes the audio file and leaves the
/// folder, its metadata, and the user's own work exactly where they were.
enum CachedOriginals {
    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Storage"
    )

    /// One original whose audio could be given back to the volume.
    struct Candidate: Identifiable, Sendable {
        let id: UUID
        let title: String
        let folderURL: URL
        let audioURL: URL
        let byteCount: Int64
        /// Whether the app already holds separated stems for it. Evicting one
        /// of these costs nothing but a re-download if it is ever separated
        /// again; evicting an unseparated original loses the only copy of a
        /// download that has not been used for anything yet.
        let hasSeparation: Bool
    }

    static func candidates(in snapshot: LibrarySnapshot) -> [Candidate] {
        let separatedIDs = Set(snapshot.tracks.compactMap(\.sourceOriginalID))
        return snapshot.originals.compactMap { original in
            guard let audioURL = original.audioURL,
                  original.sourceURL != nil else { return nil }
            let bytes = LibraryStaging.byteCount(of: audioURL)
            guard bytes > 0 else { return nil }
            return Candidate(
                id: original.id,
                title: original.title,
                folderURL: original.folderURL,
                audioURL: audioURL,
                byteCount: bytes,
                hasSeparation: separatedIDs.contains(original.id)
            )
        }
    }

    /// Removes the audio of the given originals. Returns how many bytes came
    /// back.
    @discardableResult
    static func evict(_ candidates: [Candidate]) -> Int64 {
        var reclaimed: Int64 = 0
        for candidate in candidates {
            do {
                try FileManager.default.removeItem(at: candidate.audioURL)
                reclaimed += candidate.byteCount
            } catch {
                logger.error(
                    "Could not evict a cached original: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if reclaimed > 0 {
            logger.info("Evicted \(reclaimed, privacy: .public) bytes of cached originals")
        }
        return reclaimed
    }
}
