import Foundation

/// One durable home for everything the app knows about a song.
///
/// Practice state and analysis results both belong to the *song*, not to a
/// separation of it. Re-separating with a different model produces a new
/// `Tracks/<id>/` folder, so anything kept there would be lost with the old one
/// — which is exactly what used to happen to practice settings, keyed by track
/// ID in `UserDefaults`. Both now live beside the **original**, keyed by
/// original ID, and survive every re-separation.
///
/// Writes go through `LibraryMetadata`, whose encode-and-replace is atomic, so
/// a process killed mid-write leaves the previous file rather than a truncated
/// one. Reads are deliberately non-throwing: a damaged result is a missing
/// result, never a reason a song cannot be opened.
struct SongStorage: Sendable, Equatable {
    static let practiceFilename = "practice.json"
    static let lyricsFilename = "lyrics.json"
    static let chordsFilename = "chords.json"
    static let userChordsFilename = "user-chords.json"
    static let beatsFilename = "beats.json"

    /// What the analysis phases compute. Practice state is deliberately not one
    /// of them: it is the user's own work, and no algorithm improvement can
    /// make it stale.
    static let analysisFilenames = [lyricsFilename, chordsFilename, beatsFilename]
    /// Imported charts are user data, not analysis output. They are included in
    /// accounting and backup, but never in an algorithm-version invalidation.
    static let songFilenames = analysisFilenames + [practiceFilename, userChordsFilename]

    let folderURL: URL
    /// True when the original has been deleted and this song's state has to
    /// live in the separation's own folder instead. It then dies with that
    /// separation, which is the honest outcome: there is no longer a song for
    /// it to outlive.
    let isFallback: Bool

    init(folderURL: URL, isFallback: Bool = false) {
        self.folderURL = folderURL
        self.isFallback = isFallback
    }

    /// Resolves a song's storage from its separation, preferring the original.
    static func resolve(
        originalID: UUID?,
        trackFolder: URL,
        originalsRoot: URL? = nil
    ) -> SongStorage {
        if let originalID,
           let folder = originalFolder(for: originalID, root: originalsRoot) {
            return SongStorage(folderURL: folder)
        }
        return SongStorage(folderURL: trackFolder, isFallback: true)
    }

    /// The original's folder, or `nil` when it has been deleted. Never created
    /// on demand: a folder conjured here would be an `Originals` entry with no
    /// audio in it, which every discovery pass would then have to learn to
    /// ignore.
    static func originalFolder(for originalID: UUID, root: URL? = nil) -> URL? {
        guard let root = root ?? (try? LibraryStaging.libraryRoot(named: "Originals")) else {
            return nil
        }
        let folder = root.appendingPathComponent(originalID.uuidString, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return folder
    }

    func url(for filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }

    func read<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        try? LibraryMetadata.read(type, from: url(for: filename))
    }

    func write<T: Encodable>(_ value: T, to filename: String) throws {
        try FileManager.default.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true
        )
        let destination = url(for: filename)
        try LibraryMetadata.write(value, to: destination)
        // A file created after the last library-wide pass still has to carry
        // the user's answer, or the first loop they set after turning backup
        // off would go to iCloud anyway.
        if Self.songFilenames.contains(filename) {
            Self.setExcludedFromBackup(!Self.backsUpUserData, for: destination)
        }
    }

    func remove(_ filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
    }

    /// What this song's own data costs, separately from the audio it describes.
    /// Storage accounting reports it as its own line because it is the only
    /// part of a library folder the user cannot see the size of by ear.
    static func songDataByteCount(of folder: URL) -> Int64 {
        songFilenames.reduce(0) { total, filename in
            total + LibraryStaging.byteCount(of: folder.appendingPathComponent(filename))
        }
    }

    // MARK: - Backup

    /// Whether the user's own work goes to iCloud.
    ///
    /// **Off by default.** Two categories are affected: performances, and the
    /// practice state and analysis stored beside each song. Everything else is
    /// reproducible and is excluded unconditionally, whatever this says.
    ///
    /// The consequence is worth stating plainly rather than burying, because
    /// it is the reason the toggle is worded the way it is in Settings: while
    /// this is off, restoring to a new device brings back no performances and
    /// no practice state, and nothing can reproduce either. That is the
    /// deliberate default — nothing leaves the device until the user says so —
    /// and Settings says so in as many words.
    ///
    /// Note this is not, and cannot be, a switch on iCloud Backup itself. The
    /// app only marks its own files as included or excluded; whether a backup
    /// ever runs is the user's system setting, and iOS has a per-app switch of
    /// its own that covers the whole container.
    static let userDataBackupDefaultsKey = "backUpUserDataToICloud"

    static var backsUpUserData: Bool {
        UserDefaults.standard.bool(forKey: userDataBackupDefaultsKey)
    }

    /// The rule for an original's folder.
    ///
    /// The downloaded audio is reproducible cache — it can be fetched again
    /// from its source URL — so it is always excluded, which is what keeps a
    /// library of songs out of the user's iCloud quota whatever the preference
    /// says. The practice state and analysis beside it are the user's own work
    /// and follow the preference. The folder itself is never excluded as a
    /// whole, because the two kinds of thing in it get different answers.
    static func applyBackupPolicy(to folder: URL, audioFilename: String) {
        setExcludedFromBackup(true, for: folder.appendingPathComponent(audioFilename))
        applyUserDataBackupPolicy(inSongFolder: folder)
    }

    /// The rule for a separation folder.
    ///
    /// Stems are derived: they can be produced again from the original by the
    /// model that made them, so backing them up would put hundreds of megabytes
    /// per song into the user's iCloud quota to save work a re-separation
    /// redoes. The waveform overview is derived from the stems and goes with
    /// them. A `practice.json` that fell back to living here because the
    /// original was deleted is the user's own work and follows the preference.
    static func applyBackupPolicy(toSeparation folder: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for url in contents
        where url.pathExtension.lowercased() == "wav"
            || url.lastPathComponent == "waveform.json" {
            setExcludedFromBackup(true, for: url)
        }
        applyUserDataBackupPolicy(inSongFolder: folder)
    }

    /// The rule for a performance folder, which is the one place where
    /// *everything* is the user's own work — the raw streams, the mix, and the
    /// metadata alike. So the folder is marked as a whole.
    static func applyBackupPolicy(toRecording folder: URL) {
        setExcludedFromBackup(!backsUpUserData, for: folder)
    }

    private static func applyUserDataBackupPolicy(inSongFolder folder: URL) {
        let excluded = !backsUpUserData
        for filename in songFilenames {
            let url = folder.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            setExcludedFromBackup(excluded, for: url)
        }
    }

    /// Set rather than only clear: turning the preference back on has to undo
    /// the exclusion, so this writes `false` as deliberately as it writes
    /// `true`.
    private static func setExcludedFromBackup(_ excluded: Bool, for url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? mutable.setResourceValues(values)
    }

    /// Re-applies the policy across the whole library.
    ///
    /// Called at launch and whenever the preference changes. The rule is
    /// enforced when an entry is published, but a folder written by an earlier
    /// build — or before the user last flipped the toggle — carries whatever
    /// flags it was given then, and a preference that only governed future
    /// files would be a preference about nothing the user can see. Cheap enough
    /// to redo every launch: it is a resource-value write per file, on folders
    /// the app has to enumerate anyway.
    static func applyBackupPolicyAcrossLibrary() {
        let fileManager = FileManager.default
        if let originals = try? LibraryStaging.libraryRoot(named: "Originals"),
           let folders = try? fileManager.contentsOfDirectory(
            at: originals,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            for folder in folders {
                guard let metadata = try? LibraryMetadata.read(
                    OriginalMetadata.self,
                    from: folder.appendingPathComponent(LibraryMetadata.originalFilename)
                ) else { continue }
                applyBackupPolicy(to: folder, audioFilename: metadata.audioFilename)
            }
        }
        if let tracks = try? LibraryStaging.libraryRoot(named: "Tracks"),
           let folders = try? fileManager.contentsOfDirectory(
            at: tracks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            for folder in folders { applyBackupPolicy(toSeparation: folder) }
        }
        if let recordings = try? LibraryStaging.libraryRoot(named: "Recordings"),
           let folders = try? fileManager.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            for folder in folders { applyBackupPolicy(toRecording: folder) }
        }
    }

    // MARK: - Legacy defaults

    /// Keys earlier builds wrote per song. Pre-release, so there is nothing to
    /// migrate — but without a sweep they would sit in the defaults database
    /// forever, and "no per-song state remains in `UserDefaults`" would be true
    /// only of code and not of disk.
    static let legacyPerSongDefaultsPrefixes = ["practiceSettings.v1.", "stemLevels."]

    static func purgeLegacyPerSongDefaults(_ defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where legacyPerSongDefaultsPrefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Something an analysis phase computes and caches beside the song.
///
/// `analysisVersion` is the analysis counterpart of `separationCacheVersion`:
/// improving an algorithm makes every result the old one produced wrong, and
/// bumping the constant is what makes the app recompute rather than display
/// stale output. Nothing branches on the value — a result at a version we no
/// longer produce is discarded, not migrated.
protocol AnalysisArtifact: Codable, Sendable {
    /// The version this build produces.
    static var currentAnalysisVersion: Int { get }
    static var filename: String { get }
    /// The version the stored result was produced at.
    var analysisVersion: Int { get }
}

extension SongStorage {
    func readAnalysis<T: AnalysisArtifact>(_ type: T.Type) -> T? {
        guard let value = read(type, from: T.filename),
              value.analysisVersion == T.currentAnalysisVersion else { return nil }
        return value
    }

    func writeAnalysis<T: AnalysisArtifact>(_ value: T) throws {
        // Analysis results are small, but "small" on a full volume is still a
        // failed write. One check covers lyrics, chords, and beats, since they
        // all publish through here.
        try StorageCapacity.require(StorageEstimate.analysis, for: .analysis)
        try write(value, to: T.filename)
    }
}
