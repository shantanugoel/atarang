import AVFoundation
import Foundation
import OSLog

/// What kind of thing a library folder claims to be.
enum LibraryEntryKind: String, Codable, Sendable, CaseIterable {
    case original
    case separation
    case performance

    var rootName: String {
        switch self {
        case .original: "Originals"
        case .separation: "Tracks"
        case .performance: "Recordings"
        }
    }

    var title: String {
        switch self {
        case .original: "Original"
        case .separation: "Separation"
        case .performance: "Performance"
        }
    }
}

/// What was found in one folder, in four states rather than the two the app
/// used to have.
///
/// Discovery's previous answer was `nil` — a folder it could not decode simply
/// stopped existing, with nothing written down and nothing the user could act
/// on. These are the distinctions worth making instead: whether the content is
/// intact, whether the description of it can be rebuilt from the content, and
/// whether there is anything left to rebuild from.
enum LibraryEntryStatus: Codable, Sendable, Equatable {
    /// Everything the entry claims is present and readable.
    case valid
    /// The metadata is gone or unreadable, and enough is derivable from what is
    /// on disk to write a safe replacement.
    case recoverable(String)
    /// The metadata is fine and some of the content it names is missing. The
    /// entry is not damaged, it is short.
    case incomplete(String)
    /// Neither the description nor the content survives. Quarantined rather
    /// than skipped, so it stops being invisible.
    case corrupt(String)

    var isValid: Bool { self == .valid }

    var reason: String? {
        switch self {
        case .valid: nil
        case .recoverable(let reason), .incomplete(let reason), .corrupt(let reason):
            reason
        }
    }

    var label: String {
        switch self {
        case .valid: "Valid"
        case .recoverable: "Recoverable"
        case .incomplete: "Incomplete"
        case .corrupt: "Unrecoverable"
        }
    }
}

/// One folder's findings.
///
/// Deliberately holds nothing private. A song title, a source URL, and a
/// performance's filename are all things the user might not want in a report
/// they send somewhere, and none of them helps diagnose a damaged folder. The
/// folder name is a UUID, which identifies the entry without describing it.
struct LibraryEntryReport: Codable, Sendable, Identifiable {
    let kind: LibraryEntryKind
    let folderName: String
    var status: LibraryEntryStatus
    let byteCount: Int64
    let fileCount: Int
    /// Analysis files that would not parse, by filename. These are the app's
    /// own output, so naming them exposes nothing about the song.
    var damagedAnalysisFiles: [String] = []
    /// Whether this entry was repaired or quarantined by the pass that produced
    /// the report.
    var action: String?

    var id: String { "\(kind.rawValue)/\(folderName)" }
}

/// Everything a pass found, and what it did about it.
struct LibraryIntegrityReport: Codable, Sendable {
    var generatedAt: Date
    var entries: [LibraryEntryReport]
    var availableBytes: Int64
    var breakdown: StorageBreakdown

    static let filename = "library-integrity.json"

    var problems: [LibraryEntryReport] { entries.filter { !$0.status.isValid } }
    var repairedCount: Int { entries.filter { $0.action == "repaired" }.count }
    var quarantinedCount: Int { entries.filter { $0.action == "quarantined" }.count }
}

/// Storage totals by the categories the user recognises.
struct StorageBreakdown: Codable, Sendable {
    var originals: Int64 = 0
    var separations: Int64 = 0
    var performances: Int64 = 0
    var models: Int64 = 0
    /// Practice state and analysis results, which live inside the song folders
    /// above and are therefore also counted there. Reported on its own line
    /// because it is the one part of the library whose size nothing else hints
    /// at.
    var analysis: Int64 = 0
    /// Staging directories, quarantine, and the app's scratch space.
    var temporary: Int64 = 0

    /// What the library actually occupies. `analysis` is excluded because it is
    /// already inside the three song categories.
    var total: Int64 { originals + separations + performances + models + temporary }

    static func measure(
        snapshot: LibrarySnapshot,
        root: URL? = try? LibraryStaging.applicationSupportRoot()
    ) -> StorageBreakdown {
        var breakdown = StorageBreakdown()
        breakdown.originals = snapshot.originals.reduce(0) { $0 + $1.byteCount }
        breakdown.separations = snapshot.tracks.reduce(0) { $0 + $1.byteCount }
        breakdown.performances = snapshot.recordings.reduce(0) { $0 + $1.byteCount }
        breakdown.analysis = snapshot.songDataByteCount
        guard let root else { return breakdown }
        breakdown.models = LibraryStaging.byteCount(
            of: root.appendingPathComponent("Models", isDirectory: true)
        )
        breakdown.temporary = LibraryStaging.byteCount(
            of: root.appendingPathComponent(LibraryIntegrity.quarantineRootName, isDirectory: true)
        )
            + LibraryStaging.byteCount(of: FileManager.default.temporaryDirectory)
            + stagingBytes(under: root)
        return breakdown
    }

    private static func stagingBytes(under root: URL) -> Int64 {
        var total: Int64 = 0
        for name in LibraryStaging.libraryRootNames {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for item in contents where LibraryStaging.isStagingName(item.lastPathComponent) {
                total += LibraryStaging.byteCount(of: item)
            }
        }
        return total
    }
}

/// Classifies every library folder, rebuilds what can be rebuilt, and puts what
/// cannot somewhere the user can still find it.
///
/// The rule this replaces was simple and wrong: a folder whose metadata would
/// not decode returned `nil` from discovery and vanished from the Library, with
/// no record anywhere that it had ever been there. Anything that disappears now
/// leaves a diagnostic behind, and anything derivable from the files themselves
/// — an ID that is the folder's own name, a duration that is in the audio, a
/// separation model that the set of stem files names uniquely — is derived
/// rather than lost.
enum LibraryIntegrity {
    static let quarantineRootName = "Quarantine"

    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Integrity"
    )

    // MARK: - Startup

    /// The whole pass: inspect, repair, quarantine, record.
    ///
    /// Run at launch, before the first snapshot, so a repaired folder appears
    /// in the Library on the same launch that fixed it — and again from
    /// Settings when the user asks, because the same three steps are what a
    /// rescan means. `breakdown` is supplied by the caller that has a library
    /// snapshot to measure; the launch pass runs before there is one.
    @discardableResult
    static func runPass(
        root: URL? = try? LibraryStaging.applicationSupportRoot(),
        breakdown: StorageBreakdown = StorageBreakdown()
    ) -> LibraryIntegrityReport {
        guard let root else {
            return LibraryIntegrityReport(
                generatedAt: Date(),
                entries: [],
                availableBytes: 0,
                breakdown: breakdown
            )
        }
        var entries = inspect(root: root)
        for index in entries.indices {
            switch entries[index].status {
            case .valid, .incomplete:
                continue
            case .recoverable:
                let folder = folderURL(for: entries[index], root: root)
                if repair(entries[index], at: folder) {
                    entries[index].status = .valid
                    entries[index].action = "repaired"
                    logger.info(
                        "Rebuilt metadata for \(entries[index].kind.rawValue, privacy: .public) \(entries[index].folderName, privacy: .public)"
                    )
                } else {
                    entries[index].status = .corrupt("Its metadata could not be rebuilt.")
                    if quarantine(folder, root: root) {
                        entries[index].action = "quarantined"
                    }
                }
            case .corrupt:
                let folder = folderURL(for: entries[index], root: root)
                if quarantine(folder, root: root) {
                    entries[index].action = "quarantined"
                    logger.error(
                        "Quarantined \(entries[index].kind.rawValue, privacy: .public) \(entries[index].folderName, privacy: .public): \(entries[index].status.reason ?? "", privacy: .public)"
                    )
                }
            }
        }
        let report = LibraryIntegrityReport(
            generatedAt: Date(),
            entries: entries,
            availableBytes: StorageCapacity.availableBytes(at: root),
            breakdown: breakdown
        )
        save(report, root: root)
        return report
    }

    /// The stored report, for Settings to show without repeating the pass.
    static func storedReport(root: URL? = try? LibraryStaging.applicationSupportRoot()) -> LibraryIntegrityReport? {
        guard let root else { return nil }
        return try? LibraryMetadata.read(
            LibraryIntegrityReport.self,
            from: root.appendingPathComponent(LibraryIntegrityReport.filename)
        )
    }

    static func save(
        _ report: LibraryIntegrityReport,
        root: URL? = try? LibraryStaging.applicationSupportRoot()
    ) {
        guard let root else { return }
        try? LibraryMetadata.write(
            report,
            to: root.appendingPathComponent(LibraryIntegrityReport.filename)
        )
    }

    // MARK: - Inspection

    static func inspect(root: URL) -> [LibraryEntryReport] {
        LibraryEntryKind.allCases.flatMap { kind in
            folders(in: root.appendingPathComponent(kind.rootName, isDirectory: true))
                .map { inspect($0, as: kind) }
                .sorted { $0.folderName < $1.folderName }
        }
    }

    static func inspect(_ folder: URL, as kind: LibraryEntryKind) -> LibraryEntryReport {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: folder.path
        )) ?? []
        var report = LibraryEntryReport(
            kind: kind,
            folderName: folder.lastPathComponent,
            status: .valid,
            byteCount: LibraryStaging.byteCount(of: folder),
            fileCount: contents.count
        )
        report.damagedAnalysisFiles = damagedAnalysisFiles(in: folder)
        report.status = switch kind {
        case .original: originalStatus(folder, contents: contents)
        case .separation: separationStatus(folder, contents: contents)
        case .performance: performanceStatus(folder, contents: contents)
        }
        return report
    }

    private static func originalStatus(_ folder: URL, contents: [String]) -> LibraryEntryStatus {
        let audio = audioFile(in: folder, contents: contents, extensions: ["m4a", "mp3", "wav", "caf"])
        guard let metadata = try? LibraryMetadata.read(
            OriginalMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.originalFilename)
        ) else {
            guard audio != nil else {
                return .corrupt("It has no readable description and no audio left to rebuild one from.")
            }
            return .recoverable("Its description is missing or unreadable, but its audio is intact.")
        }
        let named = folder.appendingPathComponent(metadata.audioFilename)
        if FileManager.default.fileExists(atPath: named.path) { return .valid }
        // No audio is the normal state of an evicted original, which is cache
        // by design. It is only a problem when there is no source to fetch it
        // from again.
        return metadata.sourceURL == nil
            ? .incomplete("Its audio is not on this device and there is no source to download it from again.")
            : .valid
    }

    private static func separationStatus(_ folder: URL, contents: [String]) -> LibraryEntryStatus {
        let stems = stemFiles(in: folder, contents: contents)
        guard let metadata = try? LibraryMetadata.read(
            TrackMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        ) else {
            guard !stems.isEmpty else {
                return .corrupt("It has no readable description and no stems left to rebuild one from.")
            }
            guard derivedModel(for: Set(stems.keys)) != nil else {
                return .corrupt("Its stems do not match any separation this app produces, so nothing can be said about them.")
            }
            return .recoverable("Its description is missing or unreadable, but its stems name the separation that made them.")
        }
        let missing = metadata.stems.filter { stems[$0] == nil }
        guard missing.isEmpty else {
            let names = missing.map { $0.title.lowercased() }.joined(separator: ", ")
            return .incomplete("It is missing its \(names) stem\(missing.count == 1 ? "" : "s").")
        }
        return .valid
    }

    private static func performanceStatus(_ folder: URL, contents: [String]) -> LibraryEntryStatus {
        let microphone = folder.appendingPathComponent("microphone.caf")
        let hasMicrophone = FileManager.default.fileExists(atPath: microphone.path)
        let exported = contents.first { $0.lowercased().hasSuffix(".m4a") }
        guard (try? LibraryMetadata.read(
            RecordingMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
        )) != nil else {
            guard hasMicrophone || exported != nil else {
                return .corrupt("It has no readable description and no audio left to rebuild one from.")
            }
            return .recoverable("Its description is missing or unreadable, but its audio is intact.")
        }
        guard hasMicrophone || exported != nil else {
            return .corrupt("Its audio is gone; only its description remains.")
        }
        if !hasMicrophone {
            return .incomplete("Its raw microphone and backing audio are gone, so its mix can no longer be changed.")
        }
        return .valid
    }

    /// Analysis files that will not parse.
    ///
    /// Reads of these are already non-throwing, so a damaged one cannot stop a
    /// song opening — it reads as no result. What it *can* do is sit there
    /// forever, silently suppressing an analysis the app would otherwise redo,
    /// so the pass removes it and writes the removal down.
    @discardableResult
    private static func damagedAnalysisFiles(in folder: URL) -> [String] {
        var damaged: [String] = []
        for filename in SongStorage.songFilenames {
            let url = folder.appendingPathComponent(filename)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard (try? JSONSerialization.jsonObject(with: data)) == nil else { continue }
            damaged.append(filename)
            try? FileManager.default.removeItem(at: url)
            logger.error(
                "Removed unparseable \(filename, privacy: .public) from \(folder.lastPathComponent, privacy: .public)"
            )
        }
        return damaged
    }

    // MARK: - Repair

    /// Writes a safe replacement description from what is on disk.
    ///
    /// Only facts the files themselves carry are used: the folder's name is the
    /// entry's ID, the file dates are its date, the audio holds its duration,
    /// and the set of stem filenames names the model that produced them. A
    /// title and a source URL are neither derivable nor guessable, so the title
    /// says plainly that the entry was recovered and the source is left empty.
    static func repair(_ report: LibraryEntryReport, at folder: URL) -> Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let id = UUID(uuidString: report.folderName) ?? UUID()
        let createdAt = folderDate(folder)
        switch report.kind {
        case .original:
            guard let audio = audioFile(
                in: folder,
                contents: contents,
                extensions: ["m4a", "mp3", "wav", "caf"]
            ) else { return false }
            return write(
                OriginalMetadata(
                    id: id,
                    title: recoveredTitle("song", createdAt: createdAt),
                    createdAt: createdAt,
                    sourceURL: nil,
                    sourceKey: nil,
                    audioFilename: audio.lastPathComponent
                ),
                to: folder.appendingPathComponent(LibraryMetadata.originalFilename)
            )
        case .separation:
            let stems = stemFiles(in: folder, contents: contents)
            guard let model = derivedModel(for: Set(stems.keys)) else { return false }
            return write(
                TrackMetadata(
                    id: id,
                    title: recoveredTitle("separation", createdAt: createdAt),
                    createdAt: createdAt,
                    sourceURL: nil,
                    sourceOriginalID: nil,
                    separationModel: model,
                    stems: model.stems
                ),
                to: folder.appendingPathComponent(LibraryMetadata.trackFilename)
            )
        case .performance:
            let microphone = folder.appendingPathComponent("microphone.caf")
            let exported = contents.first { $0.lowercased().hasSuffix(".m4a") }
            let measured = LibraryStaging.audioDuration(at: microphone)
                ?? exported.flatMap {
                    LibraryStaging.audioDuration(at: folder.appendingPathComponent($0))
                }
            guard let duration = measured else { return false }
            return write(
                RecordingMetadata(
                    id: id,
                    title: recoveredTitle("performance", createdAt: createdAt),
                    createdAt: createdAt,
                    duration: duration,
                    sourceTrackID: nil,
                    microphoneLevel: nil,
                    backingLevel: nil,
                    exportedFilename: exported
                ),
                to: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
            )
        }
    }

    /// A separation is identifiable by its output: no two models this app runs
    /// produce the same set of stems.
    static func derivedModel(for stems: Set<StemKind>) -> SeparationModelKind? {
        SeparationModelKind.allCases.first { Set($0.stems) == stems }
    }

    // MARK: - Quarantine

    /// Moves a folder out of the library instead of deleting it.
    ///
    /// The app cannot make sense of it, but it is still the user's data and it
    /// may still hold a playable file, so it goes somewhere inert where the
    /// storage report can account for it and the user can clear it deliberately.
    @discardableResult
    static func quarantine(_ folder: URL, root: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }
        let destinationRoot = root.appendingPathComponent(quarantineRootName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: true
            )
            let name = "\(folder.deletingLastPathComponent().lastPathComponent)-\(folder.lastPathComponent)"
            var destination = destinationRoot.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = destinationRoot.appendingPathComponent(
                    "\(name)-\(UUID().uuidString.prefix(8))",
                    isDirectory: true
                )
            }
            try FileManager.default.moveItem(at: folder, to: destination)
            var mutable = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
            return true
        } catch {
            logger.error(
                "Could not quarantine \(folder.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    static func quarantinedFolders(root: URL? = try? LibraryStaging.applicationSupportRoot()) -> [URL] {
        guard let root else { return [] }
        return folders(in: root.appendingPathComponent(quarantineRootName, isDirectory: true))
    }

    static func emptyQuarantine(root: URL? = try? LibraryStaging.applicationSupportRoot()) {
        for folder in quarantinedFolders(root: root) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Diagnostics

    /// The report as text, for the user to send somewhere.
    ///
    /// Nothing here names a song, an artist, a URL, or a performance. Every
    /// entry is a UUID, a kind, a size, and what was wrong with it — which is
    /// everything needed to diagnose the library and nothing about what is in
    /// it.
    static func diagnosticsText(_ report: LibraryIntegrityReport) -> String {
        var lines: [String] = []
        lines.append("Atarang library diagnostics")
        lines.append("Generated \(report.generatedAt.formatted(.iso8601))")
        lines.append("App version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
        lines.append("iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")
        lines.append("Storage")
        lines.append("  Free for use   \(StorageCapacity.formatted(report.availableBytes))")
        lines.append("  Originals      \(StorageCapacity.formatted(report.breakdown.originals))")
        lines.append("  Separations    \(StorageCapacity.formatted(report.breakdown.separations))")
        lines.append("  Performances   \(StorageCapacity.formatted(report.breakdown.performances))")
        lines.append("  Models         \(StorageCapacity.formatted(report.breakdown.models))")
        lines.append("  Analysis       \(StorageCapacity.formatted(report.breakdown.analysis))")
        lines.append("  Temporary      \(StorageCapacity.formatted(report.breakdown.temporary))")
        lines.append("")
        lines.append("Entries: \(report.entries.count), problems: \(report.problems.count), repaired: \(report.repairedCount), quarantined: \(report.quarantinedCount)")
        lines.append("")
        for entry in report.entries {
            var line = "\(entry.kind.title) \(entry.folderName) — \(entry.status.label)"
            line += " · \(StorageCapacity.formatted(entry.byteCount)) · \(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")"
            if let action = entry.action { line += " · \(action)" }
            lines.append(line)
            if let reason = entry.status.reason { lines.append("    \(reason)") }
            if !entry.damagedAnalysisFiles.isEmpty {
                lines.append("    Removed unparseable: \(entry.damagedAnalysisFiles.joined(separator: ", "))")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Shared

    private static func folderURL(for report: LibraryEntryReport, root: URL) -> URL {
        root.appendingPathComponent(report.kind.rootName, isDirectory: true)
            .appendingPathComponent(report.folderName, isDirectory: true)
    }

    private static func folders(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private static func audioFile(
        in folder: URL,
        contents: [String],
        extensions: [String]
    ) -> URL? {
        guard let name = contents.first(where: {
            extensions.contains(($0 as NSString).pathExtension.lowercased())
        }) else { return nil }
        let url = folder.appendingPathComponent(name)
        return LibraryStaging.audioDuration(at: url) != nil ? url : nil
    }

    private static func stemFiles(in folder: URL, contents: [String]) -> [StemKind: URL] {
        var files: [StemKind: URL] = [:]
        for name in contents where (name as NSString).pathExtension.lowercased() == "wav" {
            let base = (name as NSString).deletingPathExtension
            guard let stem = StemKind(rawValue: base) else { continue }
            let url = folder.appendingPathComponent(name)
            guard LibraryStaging.audioDuration(at: url) != nil else { continue }
            files[stem] = url
        }
        return files
    }

    private static func folderDate(_ folder: URL) -> Date {
        (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
    }

    private static func recoveredTitle(_ noun: String, createdAt: Date) -> String {
        "Recovered \(noun) — \(createdAt.formatted(.dateTime.year().month(.abbreviated).day()))"
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        do {
            try LibraryMetadata.write(value, to: url)
            return true
        } catch {
            logger.error(
                "Could not write rebuilt metadata: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}
