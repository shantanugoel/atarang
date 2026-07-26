import AVFoundation
import Foundation
import OSLog

/// Every write into the library goes through a staging directory that is only
/// published once its contents are known to be complete.
///
/// The rule is that a reader may never see a half-written entry: staging names
/// are hidden (`.staging-…`), so the discovery passes — which all skip hidden
/// files — cannot pick one up, and publication is a single rename or an atomic
/// replacement. A process killed at any point therefore leaves either the
/// previous entry or the new one, plus at worst an abandoned staging directory
/// that `sweepAbandonedStaging()` removes at the next launch.
enum LibraryStaging {
    static let prefix = ".staging-"
    /// Roots under Application Support that this app stages into.
    static let libraryRootNames = ["Originals", "Tracks", "Recordings", "Models"]

    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Library"
    )

    static func applicationSupportRoot() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func libraryRoot(named name: String) throws -> URL {
        let root = try applicationSupportRoot()
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }

    /// Creates an empty staging directory inside `root`, beside where the
    /// finished entry will land so that publishing is a same-volume rename.
    static func makeDirectory(in root: URL) throws -> URL {
        let staging = root.appendingPathComponent(
            prefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        return staging
    }

    /// Publishes staged content as `destination`.
    ///
    /// When nothing is there yet this is a rename. When something is, the
    /// existing item is only unlinked once the replacement is in place, so a
    /// known-good asset is never removed ahead of its replacement.
    static func commit(_ staging: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    static func discard(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    /// Whether an audio file exists, opens, and holds a plausible amount of
    /// audio. Used before publishing anything that claims to contain sound.
    static func audioDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0,
              file.length > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func byteCount(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        guard isDirectory.boolValue else {
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return Int64(size ?? 0)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Startup maintenance: nothing of ours can legitimately be staging while
    /// the app is launching, so every staging directory left behind belongs to
    /// a run that was killed mid-commit.
    static func sweepAbandonedStaging() {
        guard let root = try? applicationSupportRoot() else { return }
        sweepAbandonedStaging(under: root)
    }

    static func sweepAbandonedStaging(under root: URL) {
        let fileManager = FileManager.default
        for name in libraryRootNames {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            sweep(directory)
            // Models nests one level deeper: Models/<kind>/.staging-…
            guard name == "Models",
                  let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                  ) else { continue }
            for child in children { sweep(child) }
        }
        sweepExportLeftovers(in: root.appendingPathComponent("Recordings", isDirectory: true))
    }

    private static func sweep(_ directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for item in contents where isStagingName(item.lastPathComponent) {
            do {
                try fileManager.removeItem(at: item)
                logger.info("Removed abandoned staging directory \(item.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Could not remove \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Half-finished export products inside a committed recording folder. They
    /// are named distinctly so a crashed export cannot be mistaken for the
    /// shareable file the Library offers.
    private static func sweepExportLeftovers(in recordingsRoot: URL) {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for folder in folders {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            for item in contents where item.lastPathComponent.hasPrefix(".mix-")
                || item.lastPathComponent == "microphone-export.caf" {
                try? fileManager.removeItem(at: item)
            }
        }
    }
}
