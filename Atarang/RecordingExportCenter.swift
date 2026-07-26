import Foundation
import OSLog

/// One place that owns shareable-M4A exports, keyed by the recording they
/// belong to rather than by whatever song happens to be loaded.
///
/// A take the user just recorded should not lose its shareable file because
/// they opened another song, so an export runs to completion across song
/// changes and unload, and publishes itself to the Library item when it
/// finishes. Studio only *displays* an export while the same recording is still
/// loaded; it does not own it.
@MainActor
@Observable
final class RecordingExportCenter {
    static let shared = RecordingExportCenter()

    enum Status: Equatable {
        case running
        case finished(URL)
        case failed(String)
    }

    struct Entry {
        let take: RecordedTake
        let sourceTrackID: UUID?
        var status: Status
        var generation: Int
    }

    private(set) var entries: [UUID: Entry] = [:]

    /// Exports get their own serial lane. A few-second export must not queue
    /// behind a multi-minute analysis job, but two exports at once would fight
    /// over the same hardware encoder, so they are serialized among themselves.
    @ObservationIgnored private let lane = SerialLane()
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Export"
    )

    func status(for recordingID: UUID) -> Status? {
        entries[recordingID]?.status
    }

    func exportedURL(for recordingID: UUID) -> URL? {
        guard case .finished(let url) = entries[recordingID]?.status else { return nil }
        return url
    }

    func forget(_ recordingID: UUID) {
        guard entries[recordingID]?.status != .running else { return }
        entries[recordingID] = nil
    }

    func retry(_ recordingID: UUID) {
        guard let entry = entries[recordingID], entry.status != .running else { return }
        start(entry.take, sourceTrackID: entry.sourceTrackID)
    }

    /// Starts — or restarts — the export of one recording. A second call for
    /// the same recording supersedes the first: the older run's generation no
    /// longer matches, so nothing it reports is applied.
    func start(_ take: RecordedTake, sourceTrackID: UUID?) {
        let generation = (entries[take.id]?.generation ?? 0) + 1
        entries[take.id] = Entry(
            take: take,
            sourceTrackID: sourceTrackID,
            status: .running,
            generation: generation
        )
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.lane.run {
                    try await RecordingExporter.export(take: take)
                }
                guard self.entries[take.id]?.generation == generation else { return }
                self.entries[take.id]?.status = .finished(url)
                self.publish(take: take, sourceTrackID: sourceTrackID, exportedURL: url)
                self.logger.info("Shareable M4A export finished")
            } catch {
                guard self.entries[take.id]?.generation == generation else { return }
                self.entries[take.id]?.status = .failed(error.localizedDescription)
                self.logger.error("M4A export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Runs an export on the same serial lane and waits for it, for callers
    /// that manage their own metadata — the Library's mix editor.
    func exportSerially(_ take: RecordedTake) async throws -> URL {
        try await lane.run {
            try await RecordingExporter.export(take: take)
        }
    }

    /// Records the finished export against the recording on disk, so it is
    /// discoverable from the Library whether or not Studio is still showing
    /// this take.
    private func publish(take: RecordedTake, sourceTrackID: UUID?, exportedURL: URL) {
        let folder = take.microphoneURL.deletingLastPathComponent()
        let metadata = RecordingMetadata(
            id: take.id,
            title: take.title,
            createdAt: take.createdAt,
            duration: take.duration,
            sourceTrackID: sourceTrackID,
            microphoneLevel: take.microphoneLevel,
            backingLevel: take.backingLevel,
            exportedFilename: exportedURL.lastPathComponent
        )
        do {
            try LibraryMetadata.write(
                metadata,
                to: folder.appendingPathComponent(LibraryMetadata.recordingFilename)
            )
        } catch {
            logger.error(
                "Could not update recording metadata: \(error.localizedDescription, privacy: .public)"
            )
        }
        NotificationCenter.default.post(name: .atarangLibraryDidChange, object: nil)
    }
}

/// Runs submitted work one item at a time, in submission order.
///
/// An actor alone would not do this: `await`ing inside an actor method lets the
/// next call in, which is exactly what must not happen here. Chaining each new
/// task behind the previous one is what makes the lane serial.
actor SerialLane {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        // Only the most recent task is retained, and only so the next
        // submission has something to wait behind.
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
