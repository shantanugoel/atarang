import XCTest
@testable import Atarang

final class ModelInstallManifestTests: XCTestCase {
    private var root: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        artifact = root.appendingPathComponent("Kim_Vocal_2.onnx")
        try Data(repeating: 7, count: 2_048).write(to: artifact)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(
        name: String = "Kim_Vocal_2.onnx",
        byteCount: Int64 = 2_048,
        schemaVersion: Int = ModelInstallManifest.currentSchemaVersion
    ) -> ModelInstallManifest {
        ModelInstallManifest(
            schemaVersion: schemaVersion,
            model: .kimVocals,
            artifactName: name,
            byteCount: byteCount,
            sha256: nil
        )
    }

    func testAManifestMatchingTheArtifactCountsAsInstalled() {
        XCTAssertTrue(
            manifest().matches(artifactAt: artifact, expectedName: "Kim_Vocal_2.onnx")
        )
    }

    /// The failure this replaces bare `fileExists` for: a download that stopped
    /// part way leaves a file that exists and is the wrong size.
    func testATruncatedArtifactIsNotInstalled() throws {
        try Data(repeating: 7, count: 1_000).write(to: artifact)

        XCTAssertFalse(
            manifest().matches(artifactAt: artifact, expectedName: "Kim_Vocal_2.onnx")
        )
    }

    func testAMissingArtifactIsNotInstalled() throws {
        try FileManager.default.removeItem(at: artifact)

        XCTAssertFalse(
            manifest().matches(artifactAt: artifact, expectedName: "Kim_Vocal_2.onnx")
        )
    }

    func testAManifestForADifferentArtifactNameIsNotBelieved() {
        XCTAssertFalse(
            manifest(name: "something_else.onnx")
                .matches(artifactAt: artifact, expectedName: "Kim_Vocal_2.onnx")
        )
    }

    func testAManifestFromAnUnknownSchemaIsNotBelieved() {
        XCTAssertFalse(
            manifest(schemaVersion: ModelInstallManifest.currentSchemaVersion + 1)
                .matches(artifactAt: artifact, expectedName: "Kim_Vocal_2.onnx")
        )
    }

    func testAManifestSurvivesARoundTripThroughLibraryMetadata() throws {
        let url = root.appendingPathComponent(ModelInstallManifest.filename)
        let written = manifest()

        try LibraryMetadata.write(written, to: url)
        let read = try LibraryMetadata.read(ModelInstallManifest.self, from: url)

        XCTAssertEqual(read.model, written.model)
        XCTAssertEqual(read.artifactName, written.artifactName)
        XCTAssertEqual(read.byteCount, written.byteCount)
    }
}
