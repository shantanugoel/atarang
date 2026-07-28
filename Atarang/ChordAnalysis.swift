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
    private(set) var detectedChords: SongChords?
    private(set) var userCollection = UserChordCollection()
    private(set) var beatEvidence: [BeatChordEvidence] = []
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

    /// The selected chart is the runtime currency read by Chords and Sheet.
    var chords: SongChords? {
        switch userCollection.selectedSource {
        case .detected:
            detectedChords
        case .user(let id):
            userCollection.charts.first(where: { $0.id == id })?.chords
        }
    }

    var hasChords: Bool { !(chords?.isEmpty ?? true) }
    var isDetecting: Bool { detectionTask != nil }
    var hasAlternativeCharts: Bool {
        (detectedChords == nil ? 0 : 1) + userCollection.charts.filter { $0.chords != nil }.count > 1
    }

    var activeUserChart: UserChordChart? {
        guard case .user(let id) = userCollection.selectedSource else { return nil }
        return userCollection.charts.first(where: { $0.id == id })
    }

    var activeSourceLabel: String {
        activeUserChart?.name ?? "Atarang analysis"
    }

    var activeSourceDescription: String {
        if let chart = activeUserChart {
            return "\(chart.origin.label) · \(chart.alignment?.statusLabel ?? "unaligned")"
        }
        return detectedChords?.isReliable == true
            ? "Detected locally"
            : "Detected locally · uncertain"
    }

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
        detectedChords = loadStored(from: track.songStorage, duration: duration)
        userCollection = track.songStorage.read(
            UserChordCollection.self,
            from: SongStorage.userChordsFilename
        ) ?? UserChordCollection()
        beatEvidence = []
        sanitizeUserCharts(duration: duration)
        let storedSelection = userCollection.selectedSource
        repairSelection()
        if storedSelection != userCollection.selectedSource {
            saveUserCollection()
        }
    }

    func close() {
        detectionTask?.cancel()
        detectionTask = nil
        song = nil
        detectedChords = nil
        userCollection = UserChordCollection()
        beatEvidence = []
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
        let existing = detectedChords
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
                self.applyDetected(fresh)
                self.beatEvidence = result.beatEvidence
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
        let storedChord = chord?.transposed(by: -displayedSemitones)
        switch userCollection.selectedSource {
        case .detected:
            guard var value = detectedChords else { return }
            value.correct(id, to: storedChord)
            applyDetected(value)
        case .user(let chartID):
            guard let index = userCollection.charts.firstIndex(where: { $0.id == chartID }),
                  var value = userCollection.charts[index].chords else { return }
            value.correct(id, to: storedChord)
            value.updatedAt = Date()
            userCollection.charts[index].chords = value
            userCollection.charts[index].updatedAt = Date()
            saveUserCollection()
        }
    }

    func clearDetected() {
        guard let song else { return }
        detectedChords = nil
        notice = nil
        song.storage.remove(SongChords.filename)
        repairSelection()
        saveUserCollection()
    }

    func select(_ selection: ChordChartSelection) {
        userCollection.selectedSource = selection
        repairSelection()
        saveUserCollection()
    }

    /// Adds an imported chart and selects it.
    ///
    /// `aligned` is the result the import preview already computed. Passing it
    /// back means the chart the user confirmed is the chart they were shown,
    /// and the alignment is not run a second time on the main actor.
    @discardableResult
    func addUserChart(
        document: ImportedChordDocument,
        origin: UserChordOrigin,
        name: String,
        lyrics: SongLyrics?,
        grid: BeatGrid?,
        aligned: UserChordAligner.Result? = nil,
        pitchOffset: Int = 0
    ) -> UserChordChart? {
        guard let song,
              let result = aligned ?? UserChordAligner.align(
                document,
                lyrics: lyrics,
                grid: grid,
                duration: song.duration,
                evidence: beatEvidence,
                reference: detectedChords,
                pitchOffset: pitchOffset
              ) else {
            errorMessage = "This text did not contain a chord chart Atarang could add."
            return nil
        }
        let chart = UserChordChart(
            name: uniqueName(name),
            origin: origin,
            sourceMetadata: document.metadata,
            document: document,
            alignment: result.alignment,
            chords: result.chords
        )
        userCollection.charts.append(chart)
        userCollection.selectedSource = .user(chart.id)
        saveUserCollection()
        return chart
    }

    func renameUserChart(id: UUID, to proposedName: String) {
        guard let index = userCollection.charts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userCollection.charts[index].name = trimmed
        userCollection.charts[index].updatedAt = Date()
        saveUserCollection()
    }

    func updateUserChart(
        id: UUID,
        document: ImportedChordDocument,
        origin: UserChordOrigin,
        name: String,
        lyrics: SongLyrics?,
        grid: BeatGrid?,
        aligned: UserChordAligner.Result? = nil,
        pitchOffset: Int = 0
    ) -> Bool {
        guard let song,
              let index = userCollection.charts.firstIndex(where: { $0.id == id }),
              let result = aligned ?? UserChordAligner.align(
                document,
                lyrics: lyrics,
                grid: grid,
                duration: song.duration,
                evidence: beatEvidence,
                reference: detectedChords,
                pitchOffset: pitchOffset
              ) else { return false }
        var fresh = result.chords
        if let existing = userCollection.charts[index].chords, existing.hasUserEdits {
            fresh = existing.resolvingReanalysis(fresh, duration: song.duration)
        }
        userCollection.charts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        userCollection.charts[index].origin = origin
        userCollection.charts[index].sourceMetadata = document.metadata
        userCollection.charts[index].document = document
        userCollection.charts[index].alignment = result.alignment
        userCollection.charts[index].chords = fresh
        userCollection.charts[index].updatedAt = Date()
        userCollection.selectedSource = .user(id)
        saveUserCollection()
        return true
    }

    /// Rebuilds one chart's timing from its stored document.
    ///
    /// `pitchOffset` defaults to whatever the user already settled on, so a
    /// re-align does not quietly undo their decision about the chart's key.
    func realignUserChart(
        id: UUID,
        lyrics: SongLyrics?,
        grid: BeatGrid?,
        pitchOffset: Int? = nil
    ) {
        guard let song,
              let index = userCollection.charts.firstIndex(where: { $0.id == id }),
              let result = UserChordAligner.align(
                userCollection.charts[index].document,
                lyrics: lyrics,
                grid: grid,
                duration: song.duration,
                evidence: beatEvidence,
                reference: detectedChords,
                pitchOffset: pitchOffset
                    ?? userCollection.charts[index].alignment?.pitchOffset
                    ?? 0
              ) else { return }
        var fresh = result.chords
        if let existing = userCollection.charts[index].chords, existing.hasUserEdits {
            fresh = existing.resolvingReanalysis(fresh, duration: song.duration)
        }
        userCollection.charts[index].alignment = result.alignment
        userCollection.charts[index].chords = fresh
        userCollection.charts[index].updatedAt = Date()
        saveUserCollection()
    }

    func removeUserChart(id: UUID) {
        userCollection.charts.removeAll { $0.id == id }
        repairSelection()
        saveUserCollection()
    }

    private func applyDetected(_ newChords: SongChords) {
        guard let song else { return }
        var value = newChords
        value.sanitize(duration: song.duration)
        value.updatedAt = Date()
        detectedChords = value.isEmpty ? nil : value
        saveDetected()
    }

    private func saveDetected() {
        guard let song, let detectedChords else { return }
        do {
            try song.storage.write(detectedChords, to: SongChords.filename)
        } catch {
            logger.error(
                "Could not save the chord chart: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "The chord chart could not be saved to this device."
        }
    }

    private func saveUserCollection() {
        guard let song else { return }
        do {
            try song.storage.write(userCollection, to: SongStorage.userChordsFilename)
        } catch {
            logger.error(
                "Could not save imported chord charts: \(error.localizedDescription, privacy: .public)"
            )
            errorMessage = "Your imported chord charts could not be saved to this device."
        }
    }

    private func sanitizeUserCharts(duration: TimeInterval) {
        for index in userCollection.charts.indices {
            userCollection.charts[index].chords?.sanitize(duration: duration)
            if userCollection.charts[index].chords?.isEmpty == true {
                userCollection.charts[index].chords = nil
            }
        }
    }

    private func repairSelection() {
        let isUsable: Bool
        switch userCollection.selectedSource {
        case .detected:
            isUsable = detectedChords != nil
        case .user(let id):
            isUsable = userCollection.charts.contains { $0.id == id && $0.chords != nil }
        }
        guard !isUsable else { return }
        if detectedChords != nil {
            userCollection.selectedSource = .detected
        } else if let chart = userCollection.charts
            .filter({ $0.chords != nil })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            userCollection.selectedSource = .user(chart.id)
        } else {
            userCollection.selectedSource = .detected
        }
    }

    private func uniqueName(_ proposed: String) -> String {
        let base = proposed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "My chart"
            : proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Set(userCollection.charts.map { $0.name.lowercased() })
        guard names.contains(base.lowercased()) else { return base }
        var suffix = 2
        while names.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}
