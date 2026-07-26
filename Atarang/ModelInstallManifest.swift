import Foundation

/// What a completed optional-model install looks like on disk.
///
/// File existence is not evidence of an install: a download killed halfway
/// leaves a plausible-looking file, and a partially extracted `.mlmodelc`
/// directory looks installed to `fileExists` while failing to load. The
/// manifest is written last, after the artifact has been verified and
/// committed, so its presence *and* agreement with the artifact is what makes a
/// model installed.
struct ModelInstallManifest: Codable, Sendable, Equatable {
    static let filename = "manifest.json"
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var model: SeparationModelKind
    var artifactName: String
    var byteCount: Int64
    var sha256: String?
    var installedAt: Date

    init(
        schemaVersion: Int = ModelInstallManifest.currentSchemaVersion,
        model: SeparationModelKind,
        artifactName: String,
        byteCount: Int64,
        sha256: String?,
        installedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.model = model
        self.artifactName = artifactName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.installedAt = installedAt
    }

    /// Whether this manifest describes the artifact that is actually there.
    ///
    /// The recorded byte count is compared rather than the digest: rehashing
    /// 136 MB on every launch to answer "is this installed" is not a trade
    /// worth making, and a truncated or half-extracted artifact — the failure
    /// this guards against — always differs in size.
    func matches(artifactAt url: URL, expectedName: String) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              artifactName == expectedName,
              FileManager.default.fileExists(atPath: url.path),
              byteCount > 0 else { return false }
        return LibraryStaging.byteCount(of: url) == byteCount
    }
}
