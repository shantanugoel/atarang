import XCTest
@testable import Atarang

/// The persisted library formats use synthesized `Codable` conformances, so a
/// file that predates the current shape is rejected rather than silently filled
/// in with defaults. `HistoryStore` treats that rejection as "not a library
/// item", which keeps damaged metadata a visible problem instead of a guess.
final class LibraryMetadataTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTrackMetadataRoundTripsEveryField() throws {
        let original = TrackMetadata(
            id: UUID(),
            title: "Fixture",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceURL: URL(string: "https://youtu.be/abc"),
            sourceKey: "abc",
            sourceOriginalID: UUID(),
            separationModel: .htdemucs6s,
            stems: SeparationModelKind.htdemucs6s.stems
        )
        let url = folder.appendingPathComponent(LibraryMetadata.trackFilename)

        try LibraryMetadata.write(original, to: url)
        let decoded = try LibraryMetadata.read(TrackMetadata.self, from: url)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.sourceURL, original.sourceURL)
        XCTAssertEqual(decoded.sourceKey, original.sourceKey)
        XCTAssertEqual(decoded.sourceOriginalID, original.sourceOriginalID)
        XCTAssertEqual(decoded.separationModel, .htdemucs6s)
        XCTAssertEqual(decoded.stems, SeparationModelKind.htdemucs6s.stems)
        XCTAssertEqual(
            decoded.separationCacheVersion,
            SeparationModelKind.htdemucs6s.separationCacheVersion
        )
    }

    func testTrackMetadataRejectsAFileMissingItsSeparationModel() throws {
        let url = folder.appendingPathComponent(LibraryMetadata.trackFilename)
        try Data(
            #"{"id":"6E7C1B0E-0000-4000-8000-000000000001","title":"Stale","createdAt":"2025-01-01T00:00:00Z"}"#.utf8
        ).write(to: url)

        XCTAssertThrowsError(try LibraryMetadata.read(TrackMetadata.self, from: url))
    }

    func testPracticeSettingsRoundTripThroughLibraryMetadata() throws {
        var settings = SongPracticeSettings()
        settings.metronomeBPM = 132
        settings.pitchSemitones = -3
        settings.savedSections = [SavedPracticeSection(name: "Solo", start: 10, end: 20)]
        let url = folder.appendingPathComponent("practice.json")

        try LibraryMetadata.write(settings, to: url)
        let decoded = try LibraryMetadata.read(SongPracticeSettings.self, from: url)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.schemaVersion, SongPracticeSettings.currentSchemaVersion)
    }

    func testRecordingMetadataRoundTripsExportedFilename() throws {
        let original = RecordingMetadata(
            id: UUID(),
            title: "Take 1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 42,
            sourceTrackID: UUID(),
            microphoneLevel: 1,
            backingLevel: 0.7,
            exportedFilename: "take.m4a"
        )
        let url = folder.appendingPathComponent(LibraryMetadata.recordingFilename)

        try LibraryMetadata.write(original, to: url)
        let decoded = try LibraryMetadata.read(RecordingMetadata.self, from: url)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.duration, 42)
        XCTAssertEqual(decoded.sourceTrackID, original.sourceTrackID)
        XCTAssertEqual(decoded.exportedFilename, "take.m4a")
    }
}
