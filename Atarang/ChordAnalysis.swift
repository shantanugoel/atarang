import Foundation
import Observation
import OSLog

/// Running the chord detector as one of the app's long jobs.
///
/// It goes through the shared queue like everything else: it reads several stems
/// end to end, it must not run during a take, and it must be stoppable. Like the
/// beat grid it needs no model and no download — a song can have a chord chart
/// on a device that has never been on a network.
enum ChordAnalysis {
    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Chords"
    )

    /// The stems the analysis mix is built from, in the order they are worth
    /// having. Vocals and drums are absent on purpose and are not a fallback:
    /// a melody is not the harmony, and drums are broadband noise in every
    /// pitch class at once.
    static let harmonicStems: [StemKind] = [.bass, .other, .guitar, .piano, .instrumental]

    static func harmonicStems(among stems: [StemKind]) -> [StemKind] {
        harmonicStems.filter { stems.contains($0) }
    }

    static func detect(
        files: [StemKind: URL],
        grid: BeatGrid,
        duration: TimeInterval,
        title: String
    ) async throws -> AnalysisOutcome<ChordDetector.Result?> {
        // No memory gate, for the same reason beat detection has none: this is
        // the tier with no model. It holds one mono copy of the analysis mix at
        // 22.05 kHz — about twenty megabytes for a four-minute song — and a
        // gate would refuse the work in every simulator, where
        // `os_proc_available_memory()` reports zero.
        try await AnalysisQueue.shared.submit(
            kind: .chordAnalysis,
            title: title
        ) { context in
            let result = try await ChordDetector.analyze(
                files: files,
                grid: grid,
                duration: duration
            ) { progress, status in
                await context.report(status, progress: progress)
            }
            if let result {
                logger.info(
                    "Detected \(result.chords.segments.count, privacy: .public) chords in \(result.chords.key?.name ?? "an unclear key", privacy: .public), confidence \(String(format: "%.2f", result.chords.confidence), privacy: .public)"
                )
            } else {
                logger.info("No usable chord chart was found for this song")
            }
            return result
        }
    }
}

/// A song's chords, for as long as that song is open.
///
/// Split from the player for the same reason the lyrics and the beat grid are:
/// harmony is not audio, two stages read it at once, and it changes when the
/// user corrects it rather than ten times a second.
@MainActor
@Observable
final class ChordStore {
    struct Song: Equatable, Sendable {
        var storage: SongStorage
        var title: String
        var files: [StemKind: URL]
        var stems: [StemKind]
        var duration: TimeInterval
    }

    private(set) var song: Song?
    private(set) var chords: SongChords?
    /// Something to say once: an analysis that found nothing, or one whose
    /// corrections were carried across a rerun.
    var notice: String?
    var errorMessage: String?

    /// Where the chord changes say the bar starts.
    ///
    /// This is the evidence Phase 7 deferred to Phase 8: the beat grid picks its
    /// downbeat phase from the bass and the full-band envelope, and harmony is
    /// the third witness it was always meant to have. Handed to whoever owns the
    /// grid rather than reached for, so this store still knows nothing about it.
    @ObservationIgnored var onDownbeatPhase: (@MainActor (Int, Double) -> Void)?

    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Chords"
    )

    var hasChords: Bool { !(chords?.isEmpty ?? true) }
    var isDetecting: Bool { detectionTask != nil }

    /// The stems the analysis would listen to, so the interface can say what it
    /// is about to hear before it starts.
    var harmonicStems: [StemKind] {
        guard let song else { return [] }
        return ChordAnalysis.harmonicStems(among: song.stems)
    }

    // MARK: - Lifecycle

    func open(track: LocalTrack, duration: TimeInterval) {
        detectionTask?.cancel()
        detectionTask = nil
        song = Song(
            storage: track.songStorage,
            title: track.title,
            files: track.files,
            stems: track.separationModel.stems,
            duration: duration
        )
        notice = nil
        errorMessage = nil
        chords = loadStored(from: track.songStorage, duration: duration)
    }

    func close() {
        detectionTask?.cancel()
        detectionTask = nil
        song = nil
        chords = nil
        notice = nil
        errorMessage = nil
    }

    /// Reads what is on disk, with the same exception the beat grid makes.
    ///
    /// A detected chart at a version this build no longer produces is stale
    /// output and goes. A chart the user has corrected is partly their own work,
    /// and an algorithm change has no authority to delete it.
    private func loadStored(from storage: SongStorage, duration: TimeInterval) -> SongChords? {
        guard var stored = storage.read(SongChords.self, from: SongChords.filename) else {
            return nil
        }
        guard stored.hasUserEdits
                || stored.analysisVersion == SongChords.currentAnalysisVersion else {
            return nil
        }
        stored.sanitize(duration: duration)
        return stored.isEmpty ? nil : stored
    }

    // MARK: - Detection

    /// Analyses the song against a beat grid.
    ///
    /// The grid is a hard requirement, not a nicety: the chroma is averaged
    /// within beats, so without one there is nothing to average over. The stage
    /// offers to find the beat first rather than silently doing something worse.
    func detect(using grid: BeatGrid) {
        guard detectionTask == nil, let song else { return }
        guard !grid.isEmpty else {
            errorMessage = "Atarang needs the song's beats before it can follow the chords."
            return
        }
        guard !ChordAnalysis.harmonicStems(among: song.stems).isEmpty else {
            errorMessage = "This separation has no harmonic stem to take chords from."
            return
        }
        let existing = chords
        notice = nil
        errorMessage = nil

        detectionTask = Task { @MainActor [weak self] in
            defer { self?.detectionTask = nil }
            do {
                let outcome = try await ChordAnalysis.detect(
                    files: song.files,
                    grid: grid,
                    duration: song.duration,
                    title: song.title
                )
                guard let self, self.song == song else { return }
                if outcome.wasCancelled { return }
                guard let result = outcome.value ?? nil else {
                    self.notice = "Atarang could not find chords it trusts in this song. There may be too little harmony to read."
                    return
                }
                var fresh = result.chords
                // Corrections survive re-analysis. Unlike the beat grid this is
                // not all-or-nothing: someone who fixed the bridge should still
                // get a better verse out of a rerun.
                if let existing, existing.hasUserEdits {
                    fresh = existing.resolvingReanalysis(fresh, duration: song.duration)
                    self.notice = "Kept the chords you corrected and replaced the rest."
                }
                self.apply(fresh)
                if let phase = result.downbeatPhase {
                    self.onDownbeatPhase?(phase, result.downbeatConfidence)
                }
            } catch {
                guard let self, self.song == song else { return }
                self.errorMessage = error.localizedDescription
                self.logger.error(
                    "Chord analysis failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func stopDetecting() {
        AnalysisProgressCenter.shared.job(ofKind: .chordAnalysis).map {
            AnalysisProgressCenter.shared.cancel($0.token)
        }
        detectionTask?.cancel()
    }

    // MARK: - Correction

    /// Corrects one chord. `nil` means no chord, which is a correction people
    /// make as often as any other: an intro the detector filled with guesses.
    ///
    /// `displayedSemitones` is how far the audio is transposed right now. The
    /// user picks the chord they are hearing, and it is stored in the song's own
    /// key — otherwise a correction made at +2 would come back wrong the moment
    /// they returned to the original key.
    func correct(_ id: UUID, to chord: Chord?, displayedSemitones: Int = 0) {
        guard var value = chords else { return }
        value.correct(id, to: chord?.transposed(by: -displayedSemitones))
        apply(value)
    }

    func clear() {
        guard let song else { return }
        chords = nil
        notice = nil
        song.storage.remove(SongChords.filename)
    }

    private func apply(_ newChords: SongChords) {
        guard let song else { return }
        var value = newChords
        value.sanitize(duration: song.duration)
        value.updatedAt = Date()
        chords = value.isEmpty ? nil : value
        save()
    }

    private func save() {
        guard let song, let chords else { return }
        do {
            try song.storage.write(chords, to: SongChords.filename)
        } catch {
            logger.error(
                "Could not save the chord chart: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "The chord chart could not be saved to this device."
        }
    }
}
