import AVFoundation
import XCTest
@testable import Atarang

/// The capacity gate exists so an expensive job fails *before* it starts, with
/// copy that says how much more room is needed. These tests hold both halves of
/// that: that the refusal happens at the right threshold, and that the message
/// it produces is the one a person can act on.
final class StorageCapacityTests: XCTestCase {
    private var library: TemporaryLibrary!

    override func setUpWithError() throws {
        library = try TemporaryLibrary()
    }

    override func tearDown() {
        library = nil
    }

    // MARK: - The gate

    func testWorkProceedsWhenThereIsRoom() {
        XCTAssertNoThrow(
            try StorageCapacity.require(
                1_000_000_000,
                for: .separation(stemCount: 4),
                availableBytes: 2_000_000_000
            )
        )
    }

    /// The reserve is the whole point: filling the volume to the last byte is a
    /// failure even when the arithmetic says it fits.
    func testExactlyEnoughSpaceIsStillRefused() {
        XCTAssertThrowsError(
            try StorageCapacity.require(
                1_000_000_000,
                for: .separation(stemCount: 4),
                availableBytes: 1_000_000_000
            )
        )
        XCTAssertNoThrow(
            try StorageCapacity.require(
                1_000_000_000,
                for: .separation(stemCount: 4),
                availableBytes: 1_000_000_000 + StorageCapacity.reserveBytes
            )
        )
    }

    func testTheShortfallIsTheAmountThatWouldMakeItFit() throws {
        do {
            try StorageCapacity.require(
                500_000_000,
                for: .download,
                availableBytes: 100_000_000
            )
            XCTFail("A download with a fifth of the room it needs should be refused")
        } catch let error as StorageCapacityError {
            guard case .insufficient(_, let required, let shortfall) = error else {
                return XCTFail("Unexpected case")
            }
            XCTAssertEqual(required, 500_000_000)
            XCTAssertEqual(shortfall, 500_000_000 + StorageCapacity.reserveBytes - 100_000_000)
        }
    }

    /// The copy has to name the operation and state a number, because "not
    /// enough space" alone tells the user nothing they did not already suspect.
    func testTheMessageSaysWhatFailedAndHowMuchIsNeeded() throws {
        do {
            try StorageCapacity.require(
                400_000_000,
                for: .separation(stemCount: 4),
                availableBytes: 0
            )
            XCTFail("Expected a refusal")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("separate this song"), message)
            XCTAssertTrue(message.contains("free up about"), message)
            XCTAssertTrue(message.contains("MB") || message.contains("GB"), message)
            // The advice for a separation names the thing worth deleting.
            XCTAssertTrue(message.contains("Deleting separations"), message)
        }
    }

    func testEveryOperationDescribesItself() {
        let operations: [StorageCapacity.Operation] = [
            .download,
            .separation(stemCount: 4),
            .modelDownload(.htdemucs6s),
            .recording,
            .export,
            .analysis,
        ]
        for operation in operations {
            XCTAssertFalse(operation.description.isEmpty)
        }
    }

    // MARK: - Estimates

    /// Stems are float WAV, which is the reason a separation needs checking at
    /// all: a four-minute song arrives as a few megabytes and leaves as a third
    /// of a gigabyte.
    func testASeparationIsEstimatedFromItsStemCountAndLength() {
        let fourStems = StorageEstimate.separation(duration: 240, stemCount: 4)
        let sixStems = StorageEstimate.separation(duration: 240, stemCount: 6)
        XCTAssertEqual(fourStems, 240 * 352_800 * 4)
        XCTAssertEqual(sixStems, fourStems / 4 * 6)
        XCTAssertGreaterThan(fourStems, 300_000_000)
    }

    func testAnUnknownDownloadIsEstimatedGenerously() {
        XCTAssertEqual(
            StorageEstimate.download(duration: nil),
            StorageEstimate.download(duration: 60),
            "A song shorter than the floor must not lower the estimate"
        )
        XCTAssertGreaterThan(
            StorageEstimate.download(duration: 1_200),
            StorageEstimate.download(duration: nil)
        )
    }

    func testARecordingCostsFarMoreThanItsExport() {
        XCTAssertGreaterThan(
            StorageEstimate.recording(duration: 240),
            StorageEstimate.export(duration: 240) * 10
        )
    }

    /// The install needs more room than the download, because the archive, the
    /// extracted package, and the compiled model exist at the same time.
    func testInstallingAModelNeedsMoreRoomThanDownloadingIt() throws {
        for model in SeparationModelKind.allCases where model != .htdemucs {
            let download = try XCTUnwrap(model.downloadByteCount)
            let footprint = try XCTUnwrap(model.installFootprintBytes)
            XCTAssertGreaterThan(footprint, download)
        }
        XCTAssertNil(SeparationModelKind.htdemucs.downloadByteCount)
        XCTAssertNil(SeparationModelKind.htdemucs.installFootprintBytes)
    }

    /// MDX23C is the one that is unzipped and then compiled, so it is the one
    /// that needs the most headroom beyond its download.
    func testTheCompiledModelReservesTheMostHeadroom() throws {
        let mdx = try XCTUnwrap(SeparationModelKind.mdx23cInstVocHQ.installFootprintBytes)
        let onnx = try XCTUnwrap(SeparationModelKind.kimVocals.installFootprintBytes)
        XCTAssertGreaterThan(
            Double(mdx) / Double(SeparationModelKind.mdx23cInstVocHQ.downloadByteCount!),
            Double(onnx) / Double(SeparationModelKind.kimVocals.downloadByteCount!)
        )
    }

    // MARK: - Eviction

    /// Eviction is only defensible because it takes the cache and leaves the
    /// work. If it touched `practice.json` it would be deleting something the
    /// user made, and no re-download would bring it back.
    func testEvictingAnOriginalRemovesItsAudioAndKeepsItsPracticeState() throws {
        let folder = library.folder(named: "Originals/\(UUID().uuidString)")
        let audioURL = folder.appendingPathComponent("source.m4a")
        try writeSilence(to: audioURL)
        let storage = SongStorage(folderURL: folder)
        var settings = SongPracticeSettings()
        settings.loopStart = 8
        settings.loopEnd = 24
        PracticeSettingsStore().save(settings, to: storage)

        let candidate = CachedOriginals.Candidate(
            id: UUID(),
            title: "Anything",
            folderURL: folder,
            audioURL: audioURL,
            byteCount: LibraryStaging.byteCount(of: audioURL),
            hasSeparation: true
        )
        let reclaimed = CachedOriginals.evict([candidate])

        XCTAssertGreaterThan(reclaimed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(SongStorage.practiceFilename).path
            )
        )
        XCTAssertEqual(PracticeSettingsStore().load(from: storage).loopEnd, 24)
    }

    /// An original with no source cannot be fetched again, so removing its
    /// audio would be a deletion rather than an eviction.
    func testAnOriginalWithNoSourceIsNeverOfferedForEviction() throws {
        var snapshot = LibrarySnapshot()
        snapshot.originals = [
            try makeHistoryOriginal(named: "with-source", sourceURL: URL(string: "https://example.com/a")!),
            try makeHistoryOriginal(named: "recovered", sourceURL: nil),
        ]

        let candidates = CachedOriginals.candidates(in: snapshot)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.title, "with-source")
    }

    func testAlreadySeparatedOriginalsAreMarkedAsTheCheapestToEvict() throws {
        let separated = try makeHistoryOriginal(
            named: "separated",
            sourceURL: URL(string: "https://example.com/a")!
        )
        let untouched = try makeHistoryOriginal(
            named: "untouched",
            sourceURL: URL(string: "https://example.com/b")!
        )
        var snapshot = LibrarySnapshot()
        snapshot.originals = [separated, untouched]
        snapshot.tracks = [makeHistoryTrack(sourceOriginalID: separated.id)]

        let candidates = CachedOriginals.candidates(in: snapshot)

        XCTAssertEqual(
            candidates.filter(\.hasSeparation).map(\.title),
            ["separated"]
        )
    }

    // MARK: - Backup policy

    /// The preference governs the user's own work and nothing else. Stems and
    /// downloaded audio are reproducible, so they stay out of iCloud whichever
    /// way the toggle is set — that is what keeps a library of songs off the
    /// user's quota.
    func testReproducibleFilesAreExcludedWhicheverWayThePreferenceIsSet() throws {
        let original = library.folder(named: "Originals/\(UUID().uuidString)")
        try writeSilence(to: original.appendingPathComponent("source.m4a"))
        let separation = library.folder(named: "Tracks/\(UUID().uuidString)")
        try writeSilence(to: separation.appendingPathComponent("vocals.wav"))

        for backsUp in [true, false] {
            withUserDataBackup(backsUp) {
                SongStorage.applyBackupPolicy(to: original, audioFilename: "source.m4a")
                SongStorage.applyBackupPolicy(toSeparation: separation)
            }
            XCTAssertTrue(
                isExcluded(original.appendingPathComponent("source.m4a")),
                "Downloaded audio is cache with the preference \(backsUp)"
            )
            XCTAssertTrue(
                isExcluded(separation.appendingPathComponent("vocals.wav")),
                "Stems are derived with the preference \(backsUp)"
            )
        }
    }

    func testPracticeStateFollowsThePreference() throws {
        let folder = library.folder(named: "Originals/\(UUID().uuidString)")
        try writeSilence(to: folder.appendingPathComponent("source.m4a"))
        let storage = SongStorage(folderURL: folder)
        let practiceURL = folder.appendingPathComponent(SongStorage.practiceFilename)

        withUserDataBackup(false) {
            PracticeSettingsStore().save(SongPracticeSettings(), to: storage)
        }
        XCTAssertTrue(isExcluded(practiceURL))

        // And turning it on has to undo the exclusion, not merely stop adding
        // it — the whole point of a toggle is that it goes both ways.
        withUserDataBackup(true) {
            SongStorage.applyBackupPolicy(to: folder, audioFilename: "source.m4a")
        }
        XCTAssertFalse(isExcluded(practiceURL))
    }

    private func rawExclusion(_ url: URL) -> Bool? {
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup
    }

    /// A performance is the one folder where everything is the user's own work,
    /// so it is marked as a whole rather than file by file.
    func testAPerformanceFolderFollowsThePreference() throws {
        let folder = library.folder(named: "Recordings/\(UUID().uuidString)")
        try writeSilence(to: folder.appendingPathComponent("microphone.caf"))

        withUserDataBackup(false) {
            SongStorage.applyBackupPolicy(toRecording: folder)
        }
        XCTAssertTrue(isExcluded(folder))

        withUserDataBackup(true) {
            SongStorage.applyBackupPolicy(toRecording: folder)
        }
        XCTAssertFalse(isExcluded(folder))
    }

    /// A file written after the last library-wide pass still has to carry the
    /// answer, or the first loop set after turning backup off would go to
    /// iCloud anyway.
    func testAnalysisWrittenLaterStillCarriesThePreference() throws {
        let folder = library.folder(named: "Originals/\(UUID().uuidString)")
        let storage = SongStorage(folderURL: folder)

        withUserDataBackup(false) {
            try? storage.writeAnalysis(StubBackupArtifact(text: "verse"))
        }

        XCTAssertTrue(isExcluded(folder.appendingPathComponent(StubBackupArtifact.filename)))
    }

    func testBackupIsOffUntilTheUserAsksForIt() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SongStorage.userDataBackupDefaultsKey)
        defaults.removeObject(forKey: SongStorage.userDataBackupDefaultsKey)
        defer { defaults.set(previous, forKey: SongStorage.userDataBackupDefaultsKey) }

        XCTAssertFalse(SongStorage.backsUpUserData)
    }

    private func withUserDataBackup(_ enabled: Bool, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: SongStorage.userDataBackupDefaultsKey)
        defaults.set(enabled, forKey: SongStorage.userDataBackupDefaultsKey)
        body()
        defaults.set(previous, forKey: SongStorage.userDataBackupDefaultsKey)
    }

    /// Reads through a freshly built URL every time. A `URL` that has already
    /// been asked for a resource value can answer from its own cache, which in
    /// a test that flips the flag and reads it again is the difference between
    /// measuring the file and measuring the last question about it.
    private func isExcluded(_ url: URL) -> Bool {
        rawExclusion(url) == true
    }

    // MARK: - Fixtures

    private func makeHistoryOriginal(
        named name: String,
        sourceURL: URL?
    ) throws -> HistoryOriginal {
        let id = UUID()
        let folder = library.folder(named: "Originals/\(id.uuidString)")
        let audioURL = folder.appendingPathComponent("source.m4a")
        try writeSilence(to: audioURL)
        return HistoryOriginal(
            id: id,
            title: name,
            createdAt: Date(),
            sourceURL: sourceURL,
            sourceKey: nil,
            folderURL: folder,
            audioURL: audioURL,
            duration: 1,
            byteCount: LibraryStaging.byteCount(of: folder),
            songDataByteCount: 0
        )
    }

    private func makeHistoryTrack(sourceOriginalID: UUID) -> HistoryTrack {
        HistoryTrack(
            id: UUID(),
            title: "separation",
            createdAt: Date(),
            sourceURL: nil,
            sourceKey: nil,
            sourceOriginalID: sourceOriginalID,
            separationModel: .htdemucs,
            separationCacheVersion: SeparationModelKind.htdemucs.separationCacheVersion,
            folderURL: library.folder(named: "Tracks/\(UUID().uuidString)"),
            files: [:],
            duration: 1,
            byteCount: 0,
            songDataByteCount: 0
        )
    }

    private func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}

/// A stand-in analysis result, so the backup tests do not depend on the shape
/// of any real one.
private struct StubBackupArtifact: AnalysisArtifact {
    static let currentAnalysisVersion = 1
    static let filename = SongStorage.chordsFilename
    var analysisVersion = 1
    var text: String
}
