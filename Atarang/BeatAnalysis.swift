import Foundation
import Observation
import OSLog

/// Running the beat detector as one of the app's long jobs.
///
/// It goes through the shared queue like everything else: it is CPU-bound for
/// several seconds on a phone, it must not run during a take, and it must be
/// stoppable. It needs no model and no download, which is the whole point of
/// this tier — a song can have a time grid on a device that has never been on
/// a network.
enum BeatAnalysis {
    private static let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Beats"
    )

    /// The stem to take the beat from, in the order they are worth having.
    ///
    /// Isolated drums are the ideal and a two-stem separation has none, so the
    /// instrumental is the fallback — a worse envelope, because the sustained
    /// parts blur the transients, but a usable one. Vocals are last and are
    /// there only so a separation consisting of nothing else still gets an
    /// answer rather than an error.
    static let rhythmStemPreference: [StemKind] = [
        .drums, .instrumental, .other, .guitar, .piano, .bass, .vocals,
    ]

    static func rhythmStem(among stems: [StemKind]) -> StemKind? {
        rhythmStemPreference.first { stems.contains($0) }
    }

    /// Detects a grid for one song. Returns `nil` when the material has nothing
    /// steady enough to place beats in — which is a real answer about the song,
    /// not a failure.
    static func detect(
        rhythmURL: URL,
        bassURL: URL?,
        duration: TimeInterval,
        beatsPerBar: Int,
        sourceStems: [StemKind],
        title: String
    ) async throws -> AnalysisOutcome<BeatGrid?> {
        // No memory gate. That gate exists for jobs that load a model — a
        // 6-stem separation asks for three gigabytes of headroom — and this is
        // the tier that has none. It holds one mono copy of one stem at a time,
        // about forty megabytes for a four-minute song, which is the same order
        // as the waveform overview that already runs unguarded. Asking for a
        // reading that `os_proc_available_memory()` cannot give in a simulator
        // would refuse the work everywhere it is easiest to try.
        try await AnalysisQueue.shared.submit(
            kind: .beatAnalysis,
            title: title
        ) { context in
            let grid = try await BeatDetector.analyze(
                primaryURL: rhythmURL,
                bassURL: bassURL,
                duration: duration,
                beatsPerBar: beatsPerBar,
                sourceStems: sourceStems
            ) { progress, status in
                await context.report(status, progress: progress)
            }
            if let grid {
                logger.info(
                    "Detected \(grid.beats.count, privacy: .public) beats at \(grid.bpm ?? 0, privacy: .public) BPM, confidence \(String(format: "%.2f", grid.confidence), privacy: .public)"
                )
            } else {
                logger.info("No usable beat grid was found for this song")
            }
            return grid
        }
    }
}

/// A song's beat grid, for as long as that song is open.
///
/// Split from the player for the same reason the lyrics are: the grid is not
/// audio, it is read by the transport and three tools at once, and it changes
/// when the user corrects it rather than ten times a second. The player gets a
/// copy of whatever this holds, and uses it for the click, the count-in, and
/// bar snapping.
@MainActor
@Observable
final class BeatGridStore {
    struct Song: Equatable, Sendable {
        var storage: SongStorage
        var title: String
        var files: [StemKind: URL]
        var stems: [StemKind]
        var duration: TimeInterval
    }

    private(set) var song: Song?
    private(set) var grid: BeatGrid?
    /// Something to say once: a detection that found nothing, or one whose
    /// result was kept out of the way of a correction the user had made.
    var notice: String?
    var errorMessage: String?

    @ObservationIgnored private var detectionTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Beats"
    )

    var hasGrid: Bool { !(grid?.isEmpty ?? true) }
    var isDetecting: Bool { detectionTask != nil }

    /// The stem the detection would read, so the interface can say what it is
    /// about to listen to before it starts and what it listened to afterwards.
    var rhythmStem: StemKind? {
        guard let song else { return nil }
        return BeatAnalysis.rhythmStem(among: song.stems)
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
        grid = loadStored(from: track.songStorage, duration: duration)
    }

    func close() {
        detectionTask?.cancel()
        detectionTask = nil
        song = nil
        grid = nil
        notice = nil
        errorMessage = nil
    }

    /// Reads what is on disk, with one exception to the version gate.
    ///
    /// A detected grid at a version this build no longer produces is stale
    /// output and goes, exactly like a chord grid would. A grid the *user*
    /// corrected is not output at all — it is what they heard — so an algorithm
    /// change has no authority to delete it.
    private func loadStored(from storage: SongStorage, duration: TimeInterval) -> BeatGrid? {
        guard var stored = storage.read(BeatGrid.self, from: BeatGrid.filename) else {
            return nil
        }
        guard stored.isUserEdited
                || stored.analysisVersion == BeatGrid.currentAnalysisVersion else {
            return nil
        }
        stored.sanitize(duration: duration)
        return stored.isEmpty ? nil : stored
    }

    // MARK: - Detection

    /// Detects a grid, and hands whatever grid the song ends up with to
    /// `then`.
    ///
    /// The continuation is what lets the Chords stage offer one tap for "find
    /// the beat, then the chords" — chord analysis is beat-synchronous, so
    /// making the user run two detections in order would be the app asking them
    /// to know its own pipeline. It runs on every path that leaves a grid in
    /// place, including the one where a correction of theirs was kept.
    func detect(then continuation: (@MainActor (BeatGrid?) -> Void)? = nil) {
        guard detectionTask == nil, let song else { return }
        guard let rhythmStem = BeatAnalysis.rhythmStem(among: song.stems),
              let rhythmURL = song.files[rhythmStem] else {
            errorMessage = "This separation has no stem to take a beat from."
            return
        }
        let bassURL = song.files[.bass]
        let beatsPerBar = grid?.beatsPerBar ?? 4
        let existing = grid
        notice = nil
        errorMessage = nil

        detectionTask = Task { @MainActor [weak self] in
            defer { self?.detectionTask = nil }
            do {
                let outcome = try await BeatAnalysis.detect(
                    rhythmURL: rhythmURL,
                    bassURL: bassURL,
                    duration: song.duration,
                    beatsPerBar: beatsPerBar,
                    sourceStems: [rhythmStem] + (bassURL == nil ? [] : [StemKind.bass]),
                    title: song.title
                )
                guard let self, self.song == song else { return }
                // A stopped detection continues nothing: the user asked for the
                // work to end, and running the next stage anyway would be the
                // app finishing what they interrupted.
                if outcome.wasCancelled { return }
                defer { continuation?(self.grid) }
                guard let detected = outcome.value ?? nil else {
                    self.notice = "Atarang could not find a steady beat in this song. Set the tempo by hand if you need a click."
                    return
                }
                // A correction the user made outlives the analysis that
                // prompted it. Saying so is the difference between the app
                // looking broken and the app being careful.
                if let existing, existing.isUserEdited {
                    self.notice = "Kept your corrected tempo. Clear it first if you want the detected \(detected.bpm ?? 0) BPM instead."
                    return
                }
                self.apply(detected)
            } catch {
                guard let self, self.song == song else { return }
                self.errorMessage = error.localizedDescription
                self.logger.error(
                    "Beat detection failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func stopDetecting() {
        AnalysisProgressCenter.shared.job(ofKind: .beatAnalysis).map {
            AnalysisProgressCenter.shared.cancel($0.token)
        }
        detectionTask?.cancel()
    }

    // MARK: - Correction

    /// Sets the tempo by hand, which is also how a song with no detectable beat
    /// gets a grid at all.
    func setTempo(_ bpm: Double, firstDownbeat: TimeInterval? = nil) {
        guard let song, bpm > 0 else { return }
        if let grid, firstDownbeat == nil {
            apply(grid.settingTempo(bpm, duration: song.duration))
        } else {
            apply(
                BeatGrid.uniform(
                    bpm: bpm,
                    firstDownbeat: firstDownbeat ?? grid?.firstDownbeat ?? 0,
                    beatsPerBar: grid?.beatsPerBar ?? 4,
                    duration: song.duration,
                    sourceStems: grid?.sourceStems ?? []
                )
            )
        }
    }

    /// Halves or doubles the tempo, keeping the first downbeat.
    ///
    /// This is the correction, because this is the mistake. Autocorrelation
    /// hears a track with eighth-note hi-hats as being at twice its tempo, and a
    /// sparse ballad as being at half — those two account for nearly every wrong
    /// grid, and both are the same one tap to fix.
    func scaleTempo(by factor: Double) {
        guard let grid, let tempo = grid.tempo, factor > 0 else { return }
        setTempo(tempo * factor)
    }

    /// Takes the chord analysis's opinion about where the bar starts.
    ///
    /// The grid's own downbeat comes from the bass and the full-band envelope,
    /// which is two witnesses; harmony is the third, and on material where the
    /// bass rests or plays through the bar line it is the better one. It is
    /// deliberately meek: it never touches a grid the user has corrected, never
    /// touches one the detector was unsure of, and says nothing when it agrees.
    func adoptDownbeatPhase(_ phase: Int, confidence: Double) {
        guard song != nil, var grid, grid.isReliable, !grid.isUserEdited else { return }
        guard confidence >= 0.25, grid.downbeatPhase != phase % max(1, grid.beatsPerBar) else {
            return
        }
        grid = grid.settingDownbeatPhase(phase)
        apply(grid)
        notice = "Moved the bar line to where the chords change."
    }

    func setFirstDownbeat(at time: TimeInterval) {
        guard let grid else { return }
        apply(grid.settingFirstDownbeat(at: time))
    }

    func setBeatsPerBar(_ value: Int) {
        guard let grid else { return }
        apply(grid.settingBeatsPerBar(value))
    }

    /// Accepts a grid the detector was unsure about.
    ///
    /// A low-confidence grid is shown and not acted on, which is the honest
    /// default — but the user can hear the song, and if the tempo looks right
    /// to them then it is right. Confirming it is the same act as correcting
    /// it: the grid becomes theirs, and a later detection will not take it back.
    func confirm() {
        guard var value = grid else { return }
        value.isUserEdited = true
        value.confidence = 1
        apply(value)
    }

    func clear() {
        guard let song else { return }
        grid = nil
        notice = nil
        song.storage.remove(BeatGrid.filename)
    }

    private func apply(_ newGrid: BeatGrid) {
        guard let song else { return }
        var value = newGrid
        value.sanitize(duration: song.duration)
        value.updatedAt = Date()
        grid = value.isEmpty ? nil : value
        save()
    }

    private func save() {
        guard let song, let grid else { return }
        do {
            try song.storage.write(grid, to: BeatGrid.filename)
        } catch {
            logger.error(
                "Could not save the beat grid: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "The beat grid could not be saved to this device."
        }
    }
}
