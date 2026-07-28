import AVFoundation
import XCTest
@testable import Atarang

/// Discovery used to answer one question — does this folder decode — and give
/// one answer when it did not: `nil`. The folder vanished from the Library and
/// nothing anywhere recorded that it had existed.
///
/// These tests hold the four answers that replaced it, and the two promises
/// that go with them: anything derivable from the files is derived, and nothing
/// disappears without a diagnostic.
final class LibraryIntegrityTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var root: URL!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
        root = library.url
        _ = library.folder(named: "Originals")
        _ = library.folder(named: "Tracks")
        _ = library.folder(named: "Recordings")
    }

    override func tearDown() {
        library = nil
        root = nil
    }

    // MARK: - Valid

    func testAnIntactLibraryReportsNoProblems() throws {
        _ = try makeOriginal()
        _ = try makeSeparation(model: .htdemucs)
        _ = try makeRecording()

        let report = LibraryIntegrity.runPass(root: root)

        XCTAssertEqual(report.entries.count, 3)
        XCTAssertTrue(report.problems.isEmpty, "\(report.problems.map(\.status))")
        XCTAssertEqual(report.quarantinedCount, 0)
    }

    // MARK: - Recoverable

    /// A separation names its own model: no two models this app runs produce
    /// the same set of stem files, so a lost `track.json` is rebuildable from
    /// the directory listing alone.
    func testASeparationWithNoMetadataIsRebuiltFromItsStems() throws {
        let folder = try makeSeparation(model: .htdemucs6s)
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .separation })

        XCTAssertEqual(entry.action, "repaired")
        XCTAssertEqual(entry.status, .valid)
        let rebuilt = try LibraryMetadata.read(
            TrackMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )
        XCTAssertEqual(rebuilt.separationModel, .htdemucs6s)
        XCTAssertEqual(rebuilt.id.uuidString, folder.lastPathComponent)
        XCTAssertNil(rebuilt.sourceURL, "A source URL is not derivable and must not be invented")
        XCTAssertTrue(rebuilt.title.hasPrefix("Recovered"))
    }

    func testAPerformanceWithNoMetadataKeepsItsMeasuredDuration() throws {
        let folder = try makeRecording()
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
        )

        _ = LibraryIntegrity.runPass(root: root)

        let rebuilt = try LibraryMetadata.read(
            RecordingMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
        )
        XCTAssertEqual(rebuilt.id.uuidString, folder.lastPathComponent)
        XCTAssertEqual(rebuilt.duration, 0.1, accuracy: 0.02)
        XCTAssertNil(rebuilt.sourceTrackID)
    }

    func testAnOriginalWithNoMetadataIsRebuiltAroundItsAudio() throws {
        let folder = try makeOriginal()
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent(LibraryMetadata.originalFilename)
        )

        _ = LibraryIntegrity.runPass(root: root)

        let rebuilt = try LibraryMetadata.read(
            OriginalMetadata.self,
            from: folder.appendingPathComponent(LibraryMetadata.originalFilename)
        )
        XCTAssertEqual(rebuilt.audioFilename, "source.m4a")
        XCTAssertNil(rebuilt.sourceURL)
    }

    /// Unparseable JSON is a different failure from a missing file, and the one
    /// that mattered before: hand-truncated metadata threw and the folder was
    /// silently dropped.
    func testTruncatedMetadataIsTreatedAsMissingRatherThanFatal() throws {
        let folder = try makeSeparation(model: .htdemucs)
        try Data("{\"id\":\"not-final".utf8).write(
            to: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .separation })

        XCTAssertEqual(entry.action, "repaired")
        XCTAssertNoThrow(
            try LibraryMetadata.read(
                TrackMetadata.self,
                from: folder.appendingPathComponent(LibraryMetadata.trackFilename)
            )
        )
    }

    // MARK: - Incomplete

    /// Short, not damaged. A separation missing one stem is still playable and
    /// must not be quarantined out from under the user.
    func testASeparationMissingAStemIsIncompleteAndStaysWhereItIs() throws {
        let folder = try makeSeparation(model: .htdemucs)
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent("bass.wav")
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .separation })

        guard case .incomplete(let reason) = entry.status else {
            return XCTFail("Expected incomplete, got \(entry.status)")
        }
        XCTAssertTrue(reason.contains("bass"), reason)
        XCTAssertNil(entry.action)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    /// An evicted original is the intended state of a cache, not a fault.
    func testAnEvictedOriginalIsValidWhileItsSourceIsKnown() throws {
        let folder = try makeOriginal()
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent("source.m4a")
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .original })

        XCTAssertEqual(entry.status, .valid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testAnEvictedOriginalWithNoSourceIsReportedAsIncomplete() throws {
        let folder = try makeOriginal(sourceURL: nil)
        try FileManager.default.removeItem(
            at: folder.appendingPathComponent("source.m4a")
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .original })

        guard case .incomplete = entry.status else {
            return XCTFail("Expected incomplete, got \(entry.status)")
        }
    }

    // MARK: - Unrecoverable

    func testAFolderWithNothingLeftIsQuarantinedRatherThanDeleted() throws {
        let name = UUID().uuidString
        let folder = library.folder(named: "Tracks/\(name)")
        try Data("nonsense".utf8).write(to: folder.appendingPathComponent("track.json"))

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .separation })

        XCTAssertEqual(entry.action, "quarantined")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let quarantined = LibraryIntegrity.quarantinedFolders(root: root)
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(quarantined.first).lastPathComponent.hasSuffix(name),
            "A quarantined folder keeps its identity so it can be found again"
        )
    }

    /// Nothing may leave the Library silently: an entry that disappears has a
    /// record of what it was and why it went.
    func testQuarantiningLeavesADiagnosticRecord() throws {
        let folder = library.folder(named: "Recordings/\(UUID().uuidString)")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("recording.json"))

        let report = LibraryIntegrity.runPass(root: root)

        let entry = try XCTUnwrap(report.entries.first { $0.kind == .performance })
        XCTAssertEqual(entry.action, "quarantined")
        XCTAssertNotNil(entry.status.reason)
        let stored = try XCTUnwrap(LibraryIntegrity.storedReport(root: root))
        XCTAssertEqual(stored.quarantinedCount, 1)
    }

    func testStemsThatMatchNoModelCannotBeRebuiltAndAreQuarantined() throws {
        let folder = library.folder(named: "Tracks/\(UUID().uuidString)")
        // Vocals alone is not the output of any separation this app runs.
        try writeSilence(to: folder.appendingPathComponent("vocals.wav"))

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .separation })

        XCTAssertEqual(entry.action, "quarantined")
    }

    func testEmptyingQuarantineRemovesIt() throws {
        let folder = library.folder(named: "Tracks/\(UUID().uuidString)")
        try Data("nonsense".utf8).write(to: folder.appendingPathComponent("track.json"))
        _ = LibraryIntegrity.runPass(root: root)
        XCTAssertEqual(LibraryIntegrity.quarantinedFolders(root: root).count, 1)

        LibraryIntegrity.emptyQuarantine(root: root)

        XCTAssertTrue(LibraryIntegrity.quarantinedFolders(root: root).isEmpty)
    }

    // MARK: - Analysis files

    /// A damaged analysis file already could not stop a song opening — reads
    /// are non-throwing. What it could do is sit there forever suppressing the
    /// analysis the app would otherwise redo.
    func testAnUnparseableAnalysisFileIsRemovedAndRecorded() throws {
        let folder = try makeOriginal()
        try Data("{\"chords\": [".utf8).write(
            to: folder.appendingPathComponent(SongStorage.chordsFilename)
        )

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .original })

        XCTAssertEqual(entry.damagedAnalysisFiles, [SongStorage.chordsFilename])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(SongStorage.chordsFilename).path
            )
        )
        // And the song itself is untouched.
        XCTAssertEqual(entry.status, .valid)
    }

    func testAGoodAnalysisFileIsLeftAlone() throws {
        let folder = try makeOriginal()
        let storage = SongStorage(folderURL: folder)
        var settings = SongPracticeSettings()
        settings.loopStart = 4
        PracticeSettingsStore().save(settings, to: storage)

        let report = LibraryIntegrity.runPass(root: root)
        let entry = try XCTUnwrap(report.entries.first { $0.kind == .original })

        XCTAssertTrue(entry.damagedAnalysisFiles.isEmpty)
        XCTAssertEqual(PracticeSettingsStore().load(from: storage).loopStart, 4)
    }

    // MARK: - Diagnostics

    /// The report is something the user may send somewhere, so it must describe
    /// the library without describing its contents.
    func testDiagnosticsNameNoSongTitleOrSource() throws {
        _ = try makeOriginal(title: "A Very Private Song Title")
        let broken = library.folder(named: "Tracks/\(UUID().uuidString)")
        try Data("nonsense".utf8).write(to: broken.appendingPathComponent("track.json"))

        let report = LibraryIntegrity.runPass(root: root)
        let text = LibraryIntegrity.diagnosticsText(report)

        XCTAssertFalse(text.contains("A Very Private Song Title"), text)
        XCTAssertFalse(text.contains("example.com"), text)
        XCTAssertFalse(text.contains("source.m4a"), text)
        XCTAssertTrue(text.contains("Quarantined") || text.contains("quarantined"), text)
        XCTAssertTrue(text.contains("Atarang library diagnostics"))
    }

    // MARK: - Storage accounting

    func testTheBreakdownSeparatesAnalysisFromAudio() throws {
        var snapshot = LibrarySnapshot()
        snapshot.originals = [
            HistoryOriginal(
                id: UUID(),
                title: "song",
                createdAt: Date(),
                sourceURL: nil,
                sourceKey: nil,
                folderURL: root,
                audioURL: nil,
                duration: 0,
                byteCount: 1_000,
                songDataByteCount: 120
            ),
        ]

        let breakdown = StorageBreakdown.measure(snapshot: snapshot, root: root)

        XCTAssertEqual(breakdown.originals, 1_000)
        XCTAssertEqual(breakdown.analysis, 120)
        // Analysis lives inside the song folders, so counting it again in the
        // total would report the library as larger than it is.
        XCTAssertEqual(breakdown.total, breakdown.originals + breakdown.temporary)
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeOriginal(
        title: String = "song",
        sourceURL: URL? = URL(string: "https://example.com/watch")
    ) throws -> URL {
        let id = UUID()
        let folder = library.folder(named: "Originals/\(id.uuidString)")
        try writeSilence(to: folder.appendingPathComponent("source.m4a"))
        try LibraryMetadata.write(
            OriginalMetadata(
                id: id,
                title: title,
                createdAt: Date(),
                sourceURL: sourceURL,
                sourceKey: nil,
                audioFilename: "source.m4a"
            ),
            to: folder.appendingPathComponent(LibraryMetadata.originalFilename)
        )
        return folder
    }

    @discardableResult
    private func makeSeparation(model: SeparationModelKind) throws -> URL {
        let id = UUID()
        let folder = library.folder(named: "Tracks/\(id.uuidString)")
        for stem in model.stems {
            try writeSilence(
                to: folder.appendingPathComponent("\(stem.rawValue).wav")
            )
        }
        try LibraryMetadata.write(
            TrackMetadata(
                id: id,
                title: "song",
                createdAt: Date(),
                sourceURL: nil,
                sourceOriginalID: nil,
                separationModel: model,
                stems: model.stems
            ),
            to: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )
        return folder
    }

    @discardableResult
    private func makeRecording() throws -> URL {
        let id = UUID()
        let folder = library.folder(named: "Recordings/\(id.uuidString)")
        try writeSilence(to: folder.appendingPathComponent("microphone.caf"))
        try writeSilence(to: folder.appendingPathComponent("backing.caf"))
        try LibraryMetadata.write(
            RecordingMetadata(
                id: id,
                title: "take",
                createdAt: Date(),
                duration: 0.1,
                sourceTrackID: nil,
                microphoneLevel: 1,
                backingLevel: 0.7,
                exportedFilename: nil
            ),
            to: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
        )
        return folder
    }

    private func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}
