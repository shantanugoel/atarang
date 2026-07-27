import XCTest
@testable import Atarang

final class SongStorageTests: XCTestCase {
    private var library: TemporaryLibrary!
    private var originalsRoot: URL!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
        originalsRoot = library.folder(named: "Originals")
    }

    override func tearDown() {
        library = nil
        originalsRoot = nil
    }

    /// The point of the whole phase: re-separating a song produces a new
    /// `Tracks/<id>/` folder, and everything the app knows about the song has to
    /// still be there afterwards.
    func testStateSurvivesReSeparation() throws {
        let originalID = UUID()
        let originalFolder = library.folder(named: "Originals/\(originalID.uuidString)")
        let firstSeparation = library.folder(named: "Tracks/\(UUID().uuidString)")
        let secondSeparation = library.folder(named: "Tracks/\(UUID().uuidString)")

        let before = storage(originalID: originalID, trackFolder: firstSeparation)
        var settings = SongPracticeSettings()
        settings.loopStart = 10
        settings.loopEnd = 20
        settings.isLoopEnabled = true
        settings.setLevel(0.3, for: .drums)
        PracticeSettingsStore().save(settings, to: before)
        try before.writeAnalysis(StubAnalysis(text: "chorus"))

        // The first separation is deleted and replaced, as a re-separation does.
        try FileManager.default.removeItem(at: firstSeparation)
        let after = storage(originalID: originalID, trackFolder: secondSeparation)

        XCTAssertEqual(after.folderURL, originalFolder)
        XCTAssertEqual(PracticeSettingsStore().load(from: after), settings)
        XCTAssertEqual(after.readAnalysis(StubAnalysis.self)?.text, "chorus")
    }

    func testStorageFallsBackToTheTrackWhenTheOriginalIsGone() {
        let trackFolder = library.folder(named: "Tracks/\(UUID().uuidString)")

        let resolved = storage(originalID: UUID(), trackFolder: trackFolder)

        XCTAssertTrue(resolved.isFallback)
        XCTAssertEqual(resolved.folderURL, trackFolder)
    }

    func testStorageFallsBackWhenThereIsNoOriginalIDAtAll() {
        let trackFolder = library.folder(named: "Tracks/\(UUID().uuidString)")

        let resolved = storage(originalID: nil, trackFolder: trackFolder)

        XCTAssertTrue(resolved.isFallback)
        XCTAssertEqual(resolved.folderURL, trackFolder)
    }

    func testADamagedAnalysisFileReadsAsMissing() throws {
        let storage = SongStorage(folderURL: library.folder(named: "song"))
        try Data("half a fi".utf8).write(to: storage.url(for: StubAnalysis.filename))

        XCTAssertNil(storage.readAnalysis(StubAnalysis.self))
        // And the song's practice state, in its own file, is untouched.
        XCTAssertEqual(PracticeSettingsStore().load(from: storage), SongPracticeSettings())
    }

    /// `analysisVersion` is what makes improving an algorithm invalidate its
    /// cached output, the same way `separationCacheVersion` does for models.
    func testAnalysisFromAnOlderVersionIsDiscardedRatherThanShown() throws {
        let storage = SongStorage(folderURL: library.folder(named: "song"))
        try storage.write(
            StubAnalysis(analysisVersion: StubAnalysis.currentAnalysisVersion - 1, text: "stale"),
            to: StubAnalysis.filename
        )

        XCTAssertNil(storage.readAnalysis(StubAnalysis.self))
    }

    func testDeletingTheOriginalRemovesItsAnalysisAndPracticeState() throws {
        let originalID = UUID()
        let originalFolder = library.folder(named: "Originals/\(originalID.uuidString)")
        let trackFolder = library.folder(named: "Tracks/\(UUID().uuidString)")
        let resolved = storage(originalID: originalID, trackFolder: trackFolder)
        PracticeSettingsStore().save(SongPracticeSettings(), to: resolved)
        try resolved.writeAnalysis(StubAnalysis(text: "verse"))
        XCTAssertGreaterThan(SongStorage.songDataByteCount(of: originalFolder), 0)

        try FileManager.default.removeItem(at: originalFolder)

        XCTAssertEqual(SongStorage.songDataByteCount(of: originalFolder), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalFolder.path))
    }

    func testSongDataIsAccountedForSeparatelyFromAudio() throws {
        let folder = library.folder(named: "song")
        try Data(repeating: 0, count: 4_096).write(
            to: folder.appendingPathComponent("original.m4a")
        )
        let storage = SongStorage(folderURL: folder)
        PracticeSettingsStore().save(SongPracticeSettings(), to: storage)

        let songData = SongStorage.songDataByteCount(of: folder)

        XCTAssertGreaterThan(songData, 0)
        XCTAssertLessThan(songData, LibraryStaging.byteCount(of: folder))
    }

    /// The audio can be downloaded again; the practice state cannot be
    /// reconstructed by anything, so the two sides of the folder get opposite
    /// answers from the same rule.
    func testBackupExcludesTheAudioAndKeepsTheSongsOwnData() throws {
        let folder = library.folder(named: "song")
        let audioURL = folder.appendingPathComponent("source.m4a")
        try Data(repeating: 0, count: 16).write(to: audioURL)
        let storage = SongStorage(folderURL: folder)
        PracticeSettingsStore().save(SongPracticeSettings(), to: storage)

        SongStorage.applyBackupPolicy(to: folder, audioFilename: "source.m4a")

        XCTAssertEqual(
            try audioURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
        XCTAssertNotEqual(
            try storage.url(for: SongStorage.practiceFilename)
                .resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
        XCTAssertNotEqual(
            try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
    }

    func testLegacyPerSongDefaultsArePurged() {
        let suiteName = "SongStorageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(), forKey: "practiceSettings.v1.\(UUID().uuidString)")
        defaults.set(["vocals": 0.5], forKey: "stemLevels.\(UUID().uuidString)")
        defaults.set(0.7, forKey: "recordingBackingLevel")

        SongStorage.purgeLegacyPerSongDefaults(defaults)

        let remaining = defaults.dictionaryRepresentation().keys.filter { key in
            SongStorage.legacyPerSongDefaultsPrefixes.contains(where: key.hasPrefix)
        }
        XCTAssertTrue(remaining.isEmpty)
        // Global preferences are not per-song and stay where they are.
        XCTAssertEqual(defaults.float(forKey: "recordingBackingLevel"), 0.7)
    }

    private func storage(originalID: UUID?, trackFolder: URL) -> SongStorage {
        SongStorage.resolve(
            originalID: originalID,
            trackFolder: trackFolder,
            originalsRoot: originalsRoot
        )
    }
}

/// Stands in for the artifacts Phases 6 to 8 will store. This phase owns the
/// mechanism, not any particular result.
private struct StubAnalysis: AnalysisArtifact {
    static let currentAnalysisVersion = 2
    static let filename = "stub-analysis.json"

    var analysisVersion = StubAnalysis.currentAnalysisVersion
    var text: String
}
