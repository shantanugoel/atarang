import Foundation

/// One beat, in source-song seconds like every other timestamp in the app, so
/// it stays correct under speed and pitch changes.
struct Beat: Codable, Equatable, Sendable {
    var time: TimeInterval
    /// The first beat of a bar. Stored per beat rather than derived from an
    /// index so a grid with a bar of 3 in the middle of a song in 4 stays
    /// representable without inventing a metre track.
    var isDownbeat: Bool

    init(time: TimeInterval, isDownbeat: Bool = false) {
        self.time = time
        self.isDownbeat = isDownbeat
    }
}

/// Where a song's beats are.
///
/// Stored as an explicit list rather than a tempo and an offset. Real
/// performances drift — a band slows into a chorus, a live take is never one
/// number — and a grid that can only say "112 BPM from 0.31 s" would be wrong
/// by a beat halfway through such a song and have no way to express it. The
/// tempo the user sees is derived back out of the list.
///
/// The list is also what makes the grid correctable: a user who fixes the
/// tempo, the downbeat, or the bar length gets a regenerated list, and
/// `isUserEdited` then keeps re-analysis from throwing their correction away.
struct BeatGrid: AnalysisArtifact, Equatable {
    static let currentAnalysisVersion = 1
    static var filename: String { SongStorage.beatsFilename }

    /// Below this the grid is worth showing and saying is uncertain, and not
    /// worth acting on: nothing auto-aligns, nothing snaps, and the tempo is
    /// labelled rather than stated. Chosen so that a clear four-on-the-floor
    /// track passes and a rubato ballad does not.
    static let reliableConfidence = 0.55
    static let supportedBeatsPerBar = [2, 3, 4, 5, 6, 7]
    /// Two beats closer together than this are the same beat found twice.
    static let minimumBeatSpacing: TimeInterval = 0.05

    var analysisVersion = Self.currentAnalysisVersion
    var beats: [Beat] = []
    var beatsPerBar = 4
    /// How much the detector believes its own answer, 0 to 1. A hand-entered
    /// or hand-corrected grid is certain by definition and carries 1.
    var confidence: Double = 0
    /// Set by any correction. Re-analysis must never overwrite a grid the user
    /// has fixed — they heard the song and the detector did not.
    var isUserEdited = false
    /// Which stems the envelopes came from. A grid taken off isolated drums is
    /// stronger evidence than one taken off a whole instrumental, and this is
    /// what lets the interface say which happened.
    var sourceStems: [StemKind] = []
    var updatedAt = Date()

    init(
        beats: [Beat] = [],
        beatsPerBar: Int = 4,
        confidence: Double = 0,
        isUserEdited: Bool = false,
        sourceStems: [StemKind] = []
    ) {
        self.beats = beats
        self.beatsPerBar = beatsPerBar
        self.confidence = confidence
        self.isUserEdited = isUserEdited
        self.sourceStems = sourceStems
    }

    // MARK: - Shape

    var isEmpty: Bool { beats.count < 2 }

    /// True when the grid may drive the metronome, the count-in, and snapping.
    /// A grid the user has corrected is trusted whatever the detector thought.
    var isReliable: Bool { !isEmpty && (isUserEdited || confidence >= Self.reliableConfidence) }

    var downbeatTimes: [TimeInterval] {
        beats.filter(\.isDownbeat).map(\.time)
    }

    var firstDownbeat: TimeInterval? {
        beats.first(where: \.isDownbeat)?.time ?? beats.first?.time
    }

    /// The tempo, from the *median* interval rather than the mean.
    ///
    /// The median is what survives a grid with a missed beat in it: one
    /// doubled interval moves a mean by several BPM and a median not at all.
    var secondsPerBeat: TimeInterval? {
        let intervals = zip(beats.dropFirst(), beats)
            .map { $0.0.time - $0.1.time }
            .filter { $0 > 0 }
            .sorted()
        guard !intervals.isEmpty else { return nil }
        return intervals[intervals.count / 2]
    }

    var tempo: Double? {
        guard let secondsPerBeat, secondsPerBeat > 0 else { return nil }
        return 60 / secondsPerBeat
    }

    /// The tempo as the user reads and edits it.
    var bpm: Int? {
        tempo.map { Int($0.rounded()) }
    }

    /// True when the song does not hold one tempo — the reason the grid is a
    /// list. Reported so a single BPM is never presented as the whole truth.
    var hasTempoDrift: Bool {
        let intervals = zip(beats.dropFirst(), beats)
            .map { $0.0.time - $0.1.time }
            .filter { $0 > 0 }
        guard let median = secondsPerBeat, median > 0, !intervals.isEmpty else { return false }
        // A share of the beats, not the worst one. Every grid has a beat or two
        // placed a frame out, and "this song does not hold one tempo" is too
        // strong a claim to make on the strength of a single outlier.
        let wayward = intervals.filter { abs($0 - median) / median > 0.08 }
        return Double(wayward.count) / Double(intervals.count) > 0.1
    }

    var barCount: Int {
        max(0, downbeatTimes.count)
    }

    // MARK: - Lookup

    /// The beat at or before `time`, as an index into `beats`.
    func beatIndex(at time: TimeInterval) -> Int? {
        guard !beats.isEmpty else { return nil }
        var low = 0
        var high = beats.count - 1
        var result: Int?
        while low <= high {
            let middle = (low + high) / 2
            if beats[middle].time <= time {
                result = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return result
    }

    func nearestBeatTime(to time: TimeInterval) -> TimeInterval? {
        nearestTime(to: time, in: beats.map(\.time))
    }

    func nearestBarTime(to time: TimeInterval) -> TimeInterval? {
        nearestTime(to: time, in: downbeatTimes)
    }

    /// Moves a time onto the grid, or leaves it alone when there is no grid to
    /// move it onto. Callers do not have to check first, which is what keeps
    /// snapping from turning into a conditional at every call site.
    func snapped(_ time: TimeInterval, to unit: BeatSnapUnit) -> TimeInterval {
        guard isReliable else { return time }
        let snapped: TimeInterval?
        switch unit {
        case .beat: snapped = nearestBeatTime(to: time)
        case .bar: snapped = nearestBarTime(to: time)
        }
        return snapped ?? time
    }

    private func nearestTime(
        to time: TimeInterval,
        in times: [TimeInterval]
    ) -> TimeInterval? {
        guard !times.isEmpty else { return nil }
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle + 1 } else { high = middle }
        }
        let candidate = times[low]
        guard low > 0 else { return candidate }
        let previous = times[low - 1]
        return abs(previous - time) <= abs(candidate - time) ? previous : candidate
    }

    // MARK: - Construction

    /// A grid at one steady tempo, which is what a hand-entered or hand-fixed
    /// grid is: the user gives a number, and a number cannot express drift.
    static func uniform(
        bpm: Double,
        firstDownbeat: TimeInterval,
        beatsPerBar: Int,
        duration: TimeInterval,
        confidence: Double = 1,
        isUserEdited: Bool = true,
        sourceStems: [StemKind] = []
    ) -> BeatGrid {
        guard bpm > 0, bpm.isFinite, duration > 0, duration.isFinite else {
            return BeatGrid(beatsPerBar: beatsPerBar, isUserEdited: isUserEdited)
        }
        let interval = 60 / bpm
        let bar = max(2, min(12, beatsPerBar))
        let anchor = firstDownbeat.isFinite ? max(0, firstDownbeat) : 0
        // Beats before the anchor are real beats: a song whose first downbeat
        // is at 1.4 s still has a pickup, and a grid that starts at the anchor
        // would leave the click silent through it.
        let leading = Int((anchor / interval).rounded(.down))
        var beats: [Beat] = []
        var index = -leading
        while true {
            let time = anchor + Double(index) * interval
            if time > duration { break }
            if time >= 0 {
                let phase = ((index % bar) + bar) % bar
                beats.append(Beat(time: time, isDownbeat: phase == 0))
            }
            index += 1
        }
        var grid = BeatGrid(
            beats: beats,
            beatsPerBar: bar,
            confidence: min(1, max(0, confidence)),
            isUserEdited: isUserEdited,
            sourceStems: sourceStems
        )
        grid.sanitize(duration: duration)
        return grid
    }

    // MARK: - Correction

    /// Replaces the tempo, which necessarily replaces the beats.
    ///
    /// This is the destructive correction and it is destructive on purpose: a
    /// user who says "it is 96, not 128" is saying the detected list is wrong,
    /// not that it should be nudged. The bar phase is kept by anchoring the new
    /// grid at the current first downbeat.
    func settingTempo(_ bpm: Double, duration: TimeInterval) -> BeatGrid {
        Self.uniform(
            bpm: bpm,
            firstDownbeat: firstDownbeat ?? 0,
            beatsPerBar: beatsPerBar,
            duration: duration,
            sourceStems: sourceStems
        )
    }

    /// Moves the bar line without touching where the beats are.
    ///
    /// The nearest detected beat becomes the downbeat, because a downbeat that
    /// is not on a beat would put the click and the grid at odds.
    func settingFirstDownbeat(at time: TimeInterval) -> BeatGrid {
        guard let anchor = nearestBeatTime(to: time),
              let anchorIndex = beats.firstIndex(where: { $0.time == anchor }) else {
            return self
        }
        var grid = self
        for index in grid.beats.indices {
            let phase = ((index - anchorIndex) % beatsPerBar + beatsPerBar) % beatsPerBar
            grid.beats[index].isDownbeat = phase == 0
        }
        grid.isUserEdited = true
        grid.confidence = 1
        grid.updatedAt = Date()
        return grid
    }

    /// Re-marks the bar lines for a different metre, keeping the beats and the
    /// first downbeat where they are.
    func settingBeatsPerBar(_ value: Int) -> BeatGrid {
        var grid = self
        grid.beatsPerBar = max(2, min(12, value))
        grid.isUserEdited = true
        grid.confidence = 1
        grid.updatedAt = Date()
        return grid.settingFirstDownbeat(at: firstDownbeat ?? 0)
    }

    /// What a finished re-analysis is allowed to do to what is already stored.
    ///
    /// A grid the user has corrected wins outright. They listened to the song;
    /// the detector, by definition, produced the answer they corrected.
    func resolvingReanalysis(_ fresh: BeatGrid) -> BeatGrid {
        isUserEdited ? self : fresh
    }

    // MARK: - Editing

    mutating func sanitize(duration: TimeInterval) {
        beatsPerBar = max(2, min(12, beatsPerBar))
        confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        let limit = duration.isFinite ? max(0, duration) : 0
        var cleaned: [Beat] = []
        for beat in beats.sorted(by: { $0.time < $1.time }) {
            guard beat.time.isFinite, beat.time >= 0, beat.time <= limit else { continue }
            if let last = cleaned.last, beat.time - last.time < Self.minimumBeatSpacing {
                // The later of two beats that close is the duplicate; keep the
                // first, but do not lose a downbeat mark by dropping it.
                if beat.isDownbeat { cleaned[cleaned.count - 1].isDownbeat = true }
                continue
            }
            cleaned.append(beat)
        }
        beats = cleaned
        if !beats.isEmpty, !beats.contains(where: \.isDownbeat) {
            beats[0].isDownbeat = true
        }
    }
}

enum BeatSnapUnit: Sendable {
    case beat
    case bar
}
