import CryptoKit
import Foundation
import OSLog
import YoutubeDL

enum BundledYTDLP {
    static let version = "2026.07.04"
    private static let expectedSHA256 = "495be29ff4d9d4e9be7eabdfef225221e5d5282e77f2f505abc6dca80349f3fd"
    private static let logger = Logger(subsystem: "com.shantanugoel.atarang.Atarang", category: "yt-dlp")

    static func install() throws {
        guard let bundledURL = Bundle.main.url(forResource: "yt-dlp", withExtension: nil)
            ?? Bundle.main.url(forResource: "yt-dlp", withExtension: nil, subdirectory: "Resources") else {
            throw BootstrapError.resourceMissing
        }
        guard try sha256(of: bundledURL) == expectedSHA256 else {
            throw BootstrapError.checksumMismatch
        }

        let destination = YoutubeDL.pythonModuleURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path),
           try sha256(of: destination) == expectedSHA256 {
            logger.info("Using bundled yt-dlp \(version, privacy: .public) already installed at \(destination.path, privacy: .public)")
            return
        }

        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent("yt-dlp-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: bundledURL, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        logger.info("Installed bundled yt-dlp \(version, privacy: .public) at \(destination.path, privacy: .public)")
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
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
