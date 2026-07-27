import Foundation

/// A throwaway directory that stands in for `Application Support`.
///
/// Storage tests need somewhere real to write, and must not touch the running
/// simulator's library. The directory removes itself when the test lets go of
/// it, so a failing test cannot leave one behind for the next run to find.
final class TemporaryLibrary {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtarangTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A subfolder, created.
    func folder(named name: String) -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
