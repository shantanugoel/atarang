import AVFoundation
import XCTest
@testable import Atarang

final class LibraryIndexTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryIndexTests-\(UUID().uuidString)", isDirectory: true)
        for name in ["Originals", "Tracks", "Recordings"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testASnapshotDescribesEverythingTheLibraryHolds() async throws {
        let original = try makeOriginal(title: "Song")
        _ = try makeTrack(title: "Song", sourceOriginalID: original.id)
        _ = try makeRecording(title: "Take 1")

        let snapshot = await LibraryIndexer(root: root).snapshot()

        XCTAssertEqual(snapshot.originals.map(\.title), ["Song"])
        XCTAssertEqual(snapshot.tracks.map(\.title), ["Song"])
        XCTAssertEqual(snapshot.recordings.map(\.title), ["Take 1"])
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.tracks.first).byteCount, 0)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.tracks.first).duration, 0)
    }

    /// The point of the index: a second refresh must not reopen every audio file
    /// and rewalk every folder just because something elsewhere changed.
    func testUnchangedFoldersAreNotMeasuredAgain() async throws {
        let original = try makeOriginal(title: "Song")
        _ = try makeTrack(title: "Song", sourceOriginalID: original.id)
        let indexer = LibraryIndexer(root: root)

        _ = await indexer.snapshot()
        let afterFirst = await indexer.freshMeasurementCount
        _ = await indexer.snapshot()
        let afterSecond = await indexer.freshMeasurementCount

        XCTAssertEqual(afterFirst, 2)
        XCTAssertEqual(afterSecond, afterFirst, "The second pass remeasured unchanged folders")
    }

    func testOnlyTheChangedFolderIsMeasuredAgain() async throws {
        let original = try makeOriginal(title: "Song")
        _ = try makeTrack(title: "Song", sourceOriginalID: original.id)
        let indexer = LibraryIndexer(root: root)
        _ = await indexer.snapshot()
        let baseline = await indexer.freshMeasurementCount

        _ = try makeRecording(title: "Take 1")
        let snapshot = await indexer.snapshot()

        let afterChange = await indexer.freshMeasurementCount
        XCTAssertEqual(afterChange, baseline + 1)
        XCTAssertEqual(snapshot.recordings.count, 1)
    }

    func testDeletedEntriesLeaveTheIndexAndTheSnapshot() async throws {
        let original = try makeOriginal(title: "Song")
        let indexer = LibraryIndexer(root: root)
        _ = await indexer.snapshot()

        try FileManager.default.removeItem(at: original.folder)
        let snapshot = await indexer.snapshot()

        XCTAssertTrue(snapshot.originals.isEmpty)
        let stored = try LibraryMetadata.read(
            [String: IndexProbe].self,
            from: root.appendingPathComponent("library-index.json")
        )
        XCTAssertTrue(
            stored.isEmpty,
            "A folder the user deleted must not linger in the index"
        )
    }

    func testTheIndexSurvivesRestartsSoTheFirstRefreshIsCheap() async throws {
        let original = try makeOriginal(title: "Song")
        _ = try makeTrack(title: "Song", sourceOriginalID: original.id)
        _ = await LibraryIndexer(root: root).snapshot()

        // A different instance stands in for the next launch.
        let restarted = LibraryIndexer(root: root)
        _ = await restarted.snapshot()

        let measured = await restarted.freshMeasurementCount
        XCTAssertEqual(measured, 0)
    }

    // MARK: - Lookup

    func testTheSnapshotAnswersWhichSeparationsExistForASource() async throws {
        let sourceURL = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!
        let original = try makeOriginal(title: "Song", sourceURL: sourceURL)
        _ = try makeTrack(
            title: "Song",
            sourceOriginalID: original.id,
            sourceURL: sourceURL,
            separationModel: .kimVocals
        )
        let snapshot = await LibraryIndexer(root: root).snapshot()

        XCTAssertEqual(
            snapshot.separation(forSourceURL: sourceURL, using: .kimVocals)?.title,
            "Song"
        )
        XCTAssertNil(snapshot.separation(forSourceURL: sourceURL, using: .htdemucs))
        XCTAssertEqual(snapshot.separationModels(forSourceURL: sourceURL), [.kimVocals])
    }

    func testASourceWithNoSavedSeparationAnswersNothing() async throws {
        _ = try makeOriginal(
            title: "Song",
            sourceURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!
        )
        let snapshot = await LibraryIndexer(root: root).snapshot()

        let other = URL(string: "https://www.youtube.com/watch?v=zzzzzzzzzzz")!
        XCTAssertNil(snapshot.separation(forSourceURL: other, using: .htdemucs))
        XCTAssertTrue(snapshot.separationModels(forSourceURL: other).isEmpty)
    }

    /// A short-link and a full watch URL for the same video are the same song, so
    /// pasting either has to find the separation the other one produced.
    func testTheLookupMatchesTheSameVideoThroughADifferentURLForm() async throws {
        let watchURL = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!
        let shortURL = URL(string: "https://youtu.be/abcdefghijk")!
        let original = try makeOriginal(title: "Song", sourceURL: watchURL)
        _ = try makeTrack(
            title: "Song",
            sourceOriginalID: original.id,
            sourceURL: watchURL
        )
        let snapshot = await LibraryIndexer(root: root).snapshot()

        XCTAssertEqual(
            snapshot.separation(forSourceURL: shortURL, using: .htdemucs)?.title,
            "Song"
        )
    }

    // MARK: - Fixtures

    private func makeOriginal(
        title: String,
        sourceURL: URL = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!
    ) throws -> (id: UUID, folder: URL) {
        let id = UUID()
        let folder = root
            .appendingPathComponent("Originals", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSilence(to: folder.appendingPathComponent("source.wav"))
        try LibraryMetadata.write(
            OriginalMetadata(
                id: id,
                title: title,
                createdAt: Date(),
                sourceURL: sourceURL,
                sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
                audioFilename: "source.wav"
            ),
            to: folder.appendingPathComponent(LibraryMetadata.originalFilename)
        )
        return (id, folder)
    }

    private func makeTrack(
        title: String,
        sourceOriginalID: UUID,
        sourceURL: URL = URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!,
        separationModel: SeparationModelKind = .htdemucs
    ) throws -> (id: UUID, folder: URL) {
        let id = UUID()
        let folder = root
            .appendingPathComponent("Tracks", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for stem in separationModel.stems {
            try writeSilence(
                to: folder.appendingPathComponent(stem.rawValue).appendingPathExtension("wav")
            )
        }
        try LibraryMetadata.write(
            TrackMetadata(
                id: id,
                title: title,
                createdAt: Date(),
                sourceURL: sourceURL,
                sourceKey: YouTubeSource.canonicalKey(for: sourceURL),
                sourceOriginalID: sourceOriginalID,
                separationModel: separationModel,
                stems: separationModel.stems
            ),
            to: folder.appendingPathComponent(LibraryMetadata.trackFilename)
        )
        return (id, folder)
    }

    private func makeRecording(title: String) throws -> (id: UUID, folder: URL) {
        let id = UUID()
        let folder = root
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeSilence(to: folder.appendingPathComponent("microphone.caf"))
        try writeSilence(to: folder.appendingPathComponent("backing.caf"))
        try LibraryMetadata.write(
            RecordingMetadata(
                id: id,
                title: title,
                createdAt: Date(),
                duration: 12,
                sourceTrackID: nil,
                microphoneLevel: 1,
                backingLevel: 0.7,
                exportedFilename: nil
            ),
            to: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
        )
        return (id, folder)
    }

    private func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)
    }
}

/// Enough of the index file's shape to assert on it without exposing the
/// indexer's private measurement type.
private struct IndexProbe: Codable {
    let byteCount: Int64
}
