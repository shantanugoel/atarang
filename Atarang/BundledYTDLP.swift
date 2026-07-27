import CryptoKit
import Foundation
import OSLog
// `YoutubeDL` predates Swift concurrency and exposes `pythonModuleURL` as a
// mutable static. `BundledYTDLP` below is the only thing in the app that touches
// it, so the import is marked pre-concurrency here rather than app-wide.
@preconcurrency import YoutubeDL

/// The single owner of every interaction with the YoutubeDL dependency.
///
/// `YoutubeDL.pythonModuleURL` is a `public static var` in a package written
/// before Swift concurrency, and the embedded Python interpreter it points at is
/// not reentrant. Routing installation and every `yt_dlp` invocation through one
/// actor gives that shared mutable state a single owner and serializes the calls
/// that must not overlap.
actor BundledYTDLP {
    static let shared = BundledYTDLP()
    static let version = "2026.07.04"
    private static let expectedSHA256 = "495be29ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd"

    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "yt-dlp"
    )
    private let extractionLogger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "yt-dlp-download"
    )

    /// Runs yt-dlp with `argv`, installing the bundled extractor first if
    /// needed, and returns whatever it reported as an error.
    ///
    /// The return value is not decoration. yt-dlp handles an extraction failure
    /// internally and **exits zero**: a video that is private, region-locked, or
    /// DRM-protected produces `ERROR: … This video is not available`, no output
    /// file, and no thrown Swift error at all. A caller that expects yt-dlp to
    /// have written something must check that it did, and these lines are the
    /// only account of why it did not.
    @discardableResult
    func run(argv: [String]) async throws -> [String] {
        try install()
        let extractionLogger = extractionLogger
        let collector = YTDLPLogCollector()
        try await yt_dlp(argv: argv, log: { level, message in
            extractionLogger.debug("[\(level, privacy: .public)] \(message, privacy: .public)")
            collector.record(level: level, message: message)
        })
        for message in collector.errors {
            logger.error("yt-dlp: \(message, privacy: .public)")
        }
        return collector.errors
    }

    func install() throws {
        guard let bundledURL = Bundle.main.url(forResource: "yt-dlp", withExtension: nil)
            ?? Bundle.main.url(forResource: "yt-dlp", withExtension: nil, subdirectory: "Resources") else {
            throw BootstrapError.resourceMissing
        }
        guard try Self.sha256(of: bundledURL) == Self.expectedSHA256 else {
            throw BootstrapError.checksumMismatch
        }

        let destination = YoutubeDL.pythonModuleURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path),
           try Self.sha256(of: destination) == Self.expectedSHA256 {
            logger.info("Using bundled yt-dlp \(Self.version, privacy: .public) already installed at \(destination.path, privacy: .public)")
            return
        }

        // Copy first, then replace. Removing the installed extractor before the
        // replacement is in place leaves the app with no yt-dlp at all if the
        // copy fails or the process dies between the two steps.
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(LibraryStaging.prefix + "yt-dlp-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: bundledURL, to: temporary)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        logger.info("Installed bundled yt-dlp \(Self.version, privacy: .public) at \(destination.path, privacy: .public)")
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Gathers yt-dlp's error lines from whatever thread the interpreter calls back
/// on.
///
/// **Invariant:** `messages` is only ever touched inside `lock`. The logger
/// closure is handed to a Python object and invoked synchronously from the
/// interpreter, which is not the actor's executor and carries no isolation of
/// its own, so a bare array here would be a data race.
private final class YTDLPLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(level: String, message: String) {
        guard level == "error" else { return }
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private enum BootstrapError: LocalizedError {
    case resourceMissing
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "The bundled yt-dlp extractor is missing from the app."
        case .checksumMismatch:
            "The bundled yt-dlp extractor failed its integrity check."
        }
    }
}
