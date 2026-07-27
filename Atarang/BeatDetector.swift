import Accelerate
import AVFoundation
import Foundation

/// A song's onset strength over time, and how to read its indices as seconds.
///
/// Values are normalised — mean removed, half-wave rectified, divided by their
/// own standard deviation — so a quiet song and a loud one produce envelopes on
/// the same scale, and every threshold below is a number rather than a number
/// per song.
struct OnsetEnvelope: Sendable, Equatable {
    var values: [Float]
    var hopSeconds: Double

    var isEmpty: Bool { values.count < 2 }

    func time(ofFrame frame: Int) -> TimeInterval { Double(frame) * hopSeconds }

    func frame(at time: TimeInterval) -> Int {
        guard hopSeconds > 0 else { return 0 }
        return Int((time / hopSeconds).rounded())
    }

    /// The strongest value within one frame of `time`, which is what a
    /// beat-aligned reading wants: a kick a few milliseconds early is still
    /// that beat's kick.
    func strength(at time: TimeInterval) -> Float {
        guard !values.isEmpty else { return 0 }
        let centre = frame(at: time)
        var best: Float = 0
        for index in (centre - 1)...(centre + 1) where values.indices.contains(index) {
            best = max(best, values[index])
        }
        return best
    }
}

/// Finds where the beats are, with no model and no download.
///
/// The pipeline is the standard one and is standard on purpose — every step
/// here has a published reference and a known failure mode, which matters for
/// something the user is going to be told to correct when it is wrong:
///
/// 1. a spectral-flux onset envelope, computed straight off the drums stem;
/// 2. a tempo estimate by autocorrelation, weighted by a log-normal prior
///    centred at 120 BPM so the octave errors that plague autocorrelation land
///    on the side a human would pick;
/// 3. Ellis-style dynamic programming to place beats that are both near onsets
///    and evenly spaced, which is what stops a grid from chasing every fill;
/// 4. a downbeat phase chosen by where the bass lands.
///
/// Everything here is `nonisolated` and works on plain arrays so it can be
/// tested against a synthetic click track without an audio engine.
enum BeatDetector {
    /// Roughly 6 ms of time resolution at any real sample rate, which is well
    /// inside the ±15 ms the grid is held to, and a 23 ms window, which is
    /// short enough to localise a transient and long enough to have usable
    /// frequency resolution.
    static let frameSeconds = 0.023
    static let hopFraction = 4
    /// The tempo range searched. Wider than the metronome's 30–300 on purpose:
    /// the prior, not the bounds, is what decides between a tempo and its
    /// double, and a search that stops at 30 would report a 34 BPM ballad as
    /// 68.
    static let tempoRange: ClosedRange<Double> = 40...200
    /// Where the prior sits and how wide it is, in octaves. Ellis's figures.
    static let tempoPrior = (centre: 120.0, octaves: 0.9)
    /// The band a bass onset lives in. Above this is where the rest of the
    /// arrangement is, and the point of the bass envelope is that it is *not*
    /// the rest of the arrangement.
    static let bassBand: ClosedRange<Double> = 40...250

    // MARK: - Onset envelope

    /// Reads a stem and returns its onset strength over time.
    ///
    /// The file is streamed and downmixed to mono as it is read, so a
    /// nine-minute stem costs one mono copy rather than the stereo, resampled,
    /// whole-file buffer the separators need.
    static func onsetEnvelope(
        fileURL: URL,
        band: ClosedRange<Double>? = nil
    ) throws -> OnsetEnvelope {
        let samples = try monoSamples(fileURL: fileURL)
        return onsetEnvelope(
            samples: samples.values,
            sampleRate: samples.sampleRate,
            band: band
        )
    }

    static func onsetEnvelope(
        samples: [Float],
        sampleRate: Double,
        band: ClosedRange<Double>? = nil
    ) -> OnsetEnvelope {
        let size = windowSize(for: sampleRate)
        let hop = max(1, size / hopFraction)
        let hopSeconds = Double(hop) / sampleRate
        guard samples.count > size, let fft = RealFFT(size: size) else {
            return OnsetEnvelope(values: [], hopSeconds: hopSeconds)
        }

        let half = size / 2
        let lowestBin = band.map { max(1, Int($0.lowerBound * Double(size) / sampleRate)) } ?? 1
        let highestBin = band.map {
            min(half - 1, Int($0.upperBound * Double(size) / sampleRate))
        } ?? (half - 1)
        guard lowestBin <= highestBin else {
            return OnsetEnvelope(values: [], hopSeconds: hopSeconds)
        }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: size)
        var previous = [Float](repeating: 0, count: half)
        var flux: [Float] = []
        let frameCount = samples.count / hop + 1
        flux.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            // Frames are *centred* on their own timestamp. An uncentred frame
            // reports a transient up to a whole window late, which at this
            // window length would be most of the error budget spent before the
            // tempo has even been estimated.
            let start = index * hop - size / 2
            for offset in 0..<size {
                let position = start + offset
                frame[offset] = samples.indices.contains(position)
                    ? samples[position] * window[offset]
                    : 0
            }
            fft.transform(frame)
            let magnitudes = fft.magnitudes
            var sum: Float = 0
            for bin in lowestBin...highestBin {
                // Log compression before differencing, so a snare in a loud
                // chorus and the same snare in a quiet verse contribute
                // comparably. A linear difference makes the envelope a picture
                // of the mix's dynamics instead of its rhythm.
                let value = log1pf(magnitudes[bin] * 30)
                sum += max(0, value - previous[bin])
                previous[bin] = value
            }
            flux.append(sum)
        }

        return OnsetEnvelope(
            values: normalise(flux, hopSeconds: hopSeconds),
            hopSeconds: hopSeconds
        )
    }

    /// Removes the slow trend and puts the result on a unit scale.
    ///
    /// The subtraction is what makes a build-up stop reading as a continuous
    /// onset, and the division is what lets every threshold downstream be a
    /// constant rather than a fraction of this particular song's loudness.
    static func normalise(_ values: [Float], hopSeconds: Double) -> [Float] {
        guard !values.isEmpty else { return [] }
        let span = max(1, Int(0.5 / max(hopSeconds, 0.0001)))
        var prefix = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        var detrended = [Float](repeating: 0, count: values.count)
        for index in values.indices {
            let low = max(0, index - span)
            let high = min(values.count, index + span + 1)
            let mean = (prefix[high] - prefix[low]) / Float(high - low)
            detrended[index] = max(0, values[index] - mean)
        }
        var mean: Float = 0
        var deviation: Float = 0
        vDSP_normalize(
            detrended,
            1,
            nil,
            1,
            &mean,
            &deviation,
            vDSP_Length(detrended.count)
        )
        guard deviation > 0 else { return detrended }
        var scale = 1 / deviation
        var scaled = [Float](repeating: 0, count: detrended.count)
        vDSP_vsmul(detrended, 1, &scale, &scaled, 1, vDSP_Length(detrended.count))
        return scaled
    }

    // MARK: - Tempo

    struct TempoEstimate: Sendable, Equatable {
        var bpm: Double
        /// How far the winning period stands above the rest of the field, 0 to
        /// 1. A drum machine scores near 1; a rubato piano ballad scores near 0
        /// and is why the grid can say it does not know.
        var salience: Double
    }

    /// Estimates one tempo for the whole song by weighted autocorrelation.
    ///
    /// The weighting is the whole trick. Autocorrelation cannot tell a tempo
    /// from half or double it — both are genuinely periodic — so the raw peaks
    /// of a 150 BPM song appear at 75, 150, and 300. Weighting by a log-normal
    /// centred at 120 BPM picks the one a person would tap, which is the only
    /// definition of "right" that this has.
    static func estimateTempo(
        envelope: OnsetEnvelope,
        range: ClosedRange<Double> = tempoRange
    ) -> TempoEstimate? {
        let values = envelope.values
        let hop = envelope.hopSeconds
        guard values.count > 16, hop > 0 else { return nil }
        let shortestLag = max(1, Int((60 / range.upperBound / hop).rounded()))
        let longestLag = min(values.count - 1, Int((60 / range.lowerBound / hop).rounded()))
        guard shortestLag < longestLag else { return nil }

        let correlationLimit = longestLag
        var correlation = [Double](repeating: 0, count: correlationLimit + 1)
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in shortestLag...correlationLimit {
                var sum: Float = 0
                vDSP_dotpr(base + lag, 1, base, 1, &sum, vDSP_Length(values.count - lag))
                correlation[lag] = Double(sum) / Double(values.count - lag)
            }
        }

        var scores = [Double](repeating: 0, count: longestLag + 1)
        for lag in shortestLag...longestLag {
            let bpm = 60 / (Double(lag) * hop)
            let octaves = log2(bpm / tempoPrior.centre) / tempoPrior.octaves
            let weight = exp(-0.5 * octaves * octaves)
            // The prior alone, deliberately. Adding the correlation at two and
            // three times the period — a comb filter — reads as thorough and
            // systematically picks the *faster* reading, because a song whose
            // beat is periodic is also periodic at every subdivision of it. On
            // any track with eighth-note hi-hats, which is most of them, that is
            // a reliable way to report double tempo.
            scores[lag] = weight * correlation[lag]
        }

        let searched = scores[shortestLag...longestLag]
        guard let best = searched.max(), best > 0,
              let bestLag = (shortestLag...longestLag).first(where: { scores[$0] == best }) else {
            return nil
        }
        let mean = searched.reduce(0, +) / Double(searched.count)
        let salience = min(1, max(0, (best - mean) / best))

        // Sub-frame interpolation: one frame is 6 ms, which at 120 BPM is a
        // whole BPM of error before the beats are even placed.
        var lag = Double(bestLag)
        if bestLag > shortestLag, bestLag < longestLag {
            let before = scores[bestLag - 1]
            let after = scores[bestLag + 1]
            let denominator = before - 2 * best + after
            if denominator != 0 {
                let delta = 0.5 * (before - after) / denominator
                if abs(delta) <= 0.5 { lag += delta }
            }
        }
        return TempoEstimate(bpm: 60 / (lag * hop), salience: salience)
    }

    /// Halves a tempo that is really a subdivision.
    ///
    /// Autocorrelation cannot tell a beat from an eighth-note hi-hat pattern
    /// over it — both are exactly periodic — and the prior only penalises the
    /// faster reading, it does not rule it out. What does tell them apart is
    /// that a subdivision *alternates*: on a track counted at twice its tempo,
    /// every other placed beat has a kick or a snare under it and the ones in
    /// between have only the hat. If that alternation is there, the slower
    /// reading is the one a person would tap.
    ///
    /// Only tempi above `halvingThreshold` are candidates, so a song genuinely
    /// at 100 with a backbeat — where the strengths also alternate, between the
    /// kick and the snare — is never halved to 50.
    static let halvingThreshold = 140.0
    static let alternationRatio = 0.75

    static func resolvedTempo(
        envelope: OnsetEnvelope,
        estimate: TempoEstimate
    ) -> TempoEstimate {
        guard estimate.bpm > halvingThreshold,
              estimate.bpm / 2 >= tempoRange.lowerBound else { return estimate }
        let frames = trackBeats(envelope: envelope, bpm: estimate.bpm)
        guard frames.count > 8 else { return estimate }
        var strengths: [[Double]] = [[], []]
        for (index, frame) in frames.enumerated() where envelope.values.indices.contains(frame) {
            strengths[index % 2].append(Double(envelope.values[frame]))
        }
        let means = strengths.map { $0.isEmpty ? 0 : $0.reduce(0, +) / Double($0.count) }
        guard let weakest = means.min(), let strongest = means.max(), strongest > 0 else {
            return estimate
        }
        guard weakest / strongest < alternationRatio else { return estimate }
        return TempoEstimate(bpm: estimate.bpm / 2, salience: estimate.salience)
    }

    // MARK: - Beat tracking

    /// Places beats with Ellis's dynamic program.
    ///
    /// Every frame gets the best score achievable by arriving at it from some
    /// earlier beat, where "best" trades the onset strength here against how
    /// close the gap is to the estimated period. Because the decision is made
    /// over the whole song at once and only then traced back, a bar of silence
    /// or a fill does not throw the grid off — the path through it is simply
    /// the one the rest of the song pays for.
    ///
    /// `tightness` is how much an off-period gap costs. Ellis's 6 keeps the
    /// grid steady without making it deaf to real tempo drift.
    static func trackBeats(
        envelope: OnsetEnvelope,
        bpm: Double,
        tightness: Double = 6
    ) -> [Int] {
        let values = envelope.values
        guard values.count > 4, bpm > 0, envelope.hopSeconds > 0 else { return [] }
        let period = 60 / bpm / envelope.hopSeconds
        guard period >= 2, period < Double(values.count) else { return [] }

        let earliest = Int((2 * period).rounded())
        let latest = max(1, Int((period / 2).rounded()))
        var transitionCost = [Double](repeating: 0, count: earliest + 1)
        for gap in latest...earliest {
            let ratio = Double(gap) / period
            transitionCost[gap] = -tightness * pow(log(ratio), 2)
        }

        var cumulative = [Double](repeating: 0, count: values.count)
        var backlink = [Int](repeating: -1, count: values.count)
        for index in values.indices {
            var bestScore = -Double.infinity
            var bestSource = -1
            let lowest = max(0, index - earliest)
            let highest = index - latest
            if lowest <= highest {
                for source in lowest...highest {
                    let score = cumulative[source] + transitionCost[index - source]
                    if score > bestScore {
                        bestScore = score
                        bestSource = source
                    }
                }
            }
            if bestSource < 0 {
                cumulative[index] = Double(values[index])
            } else {
                // The score *accumulates* along the path rather than being
                // blended with it. That is what makes it grow through the song
                // and makes "the last strong peak" a meaningful way to find the
                // final beat; a running average would peak wherever the drummer
                // happened to hit hardest and the grid would stop there.
                cumulative[index] = Double(values[index]) + bestScore
                backlink[index] = bestSource
            }
        }

        guard let last = lastBeat(in: cumulative) else { return [] }
        var beats: [Int] = []
        var cursor = last
        while cursor >= 0 {
            beats.append(cursor)
            cursor = backlink[cursor]
        }
        return trimmed(Array(beats.reversed()), values: values)
    }

    /// Drops leading and trailing beats that have no onset under them.
    ///
    /// The path has to start somewhere, and with nothing behind it the first
    /// frame of the song scores as well as anything — so an untrimmed grid
    /// habitually begins with a beat at 0:00 that nothing was played on. The
    /// same happens after the last note.
    private static func trimmed(_ beats: [Int], values: [Float]) -> [Int] {
        guard !beats.isEmpty else { return beats }
        let strengths = beats.map { values.indices.contains($0) ? Double(values[$0]) : 0 }
        let threshold = 0.5 * strengths.reduce(0, +) / Double(strengths.count)
        var lower = 0
        var upper = beats.count - 1
        while lower <= upper, strengths[lower] < threshold { lower += 1 }
        while upper > lower, strengths[upper] < threshold { upper -= 1 }
        guard lower <= upper else { return beats }
        return Array(beats[lower...upper])
    }

    /// Where to start tracing back from.
    ///
    /// The last *peak* worth calling a beat, rather than the highest score:
    /// the score keeps climbing to the end of the song, so its maximum is
    /// usually the final frame, which is silence after the last note.
    private static func lastBeat(in cumulative: [Double]) -> Int? {
        var peaks: [Int] = []
        for index in 1..<max(1, cumulative.count - 1)
        where cumulative[index] > cumulative[index - 1]
            && cumulative[index] >= cumulative[index + 1] {
            peaks.append(index)
        }
        guard !peaks.isEmpty else {
            return cumulative.indices.max(by: { cumulative[$0] < cumulative[$1] })
        }
        let sorted = peaks.map { cumulative[$0] }.sorted()
        let median = sorted[sorted.count / 2]
        return peaks.last { cumulative[$0] * 2 > median } ?? peaks.last
    }

    /// Moves a beat onto the peak it belongs to, to a fraction of a frame.
    ///
    /// The dynamic program works in whole frames because it has to; the beat
    /// itself does not land on a frame boundary. Parabolic interpolation across
    /// the three samples around the peak recovers most of the difference, which
    /// is a few milliseconds of the fifteen the grid is allowed.
    static func refinedTime(ofFrame frame: Int, in envelope: OnsetEnvelope) -> TimeInterval {
        let values = envelope.values
        guard values.indices.contains(frame - 1), values.indices.contains(frame + 1) else {
            return envelope.time(ofFrame: max(0, frame))
        }
        let before = Double(values[frame - 1])
        let here = Double(values[frame])
        let after = Double(values[frame + 1])
        let denominator = before - 2 * here + after
        guard denominator < 0 else { return envelope.time(ofFrame: frame) }
        let delta = 0.5 * (before - after) / denominator
        guard abs(delta) <= 0.5 else { return envelope.time(ofFrame: frame) }
        return (Double(frame) + delta) * envelope.hopSeconds
    }

    // MARK: - Downbeats

    /// Chooses which of the `beatsPerBar` phases is the downbeat.
    ///
    /// Bass is the evidence because it is the part that most reliably states
    /// the bar: chords change on the one far more often than anywhere else, and
    /// a bass note is what announces it. The full-band envelope is included at
    /// half weight so a song where the bass rests through a section still has
    /// something to vote with.
    static func downbeatPhase(
        beatTimes: [TimeInterval],
        bass: OnsetEnvelope,
        onsets: OnsetEnvelope,
        beatsPerBar: Int
    ) -> (phase: Int, confidence: Double) {
        guard beatsPerBar > 1, beatTimes.count > beatsPerBar else { return (0, 0) }
        var scores = [Double](repeating: 0, count: beatsPerBar)
        var counts = [Double](repeating: 0, count: beatsPerBar)
        for (index, time) in beatTimes.enumerated() {
            let phase = index % beatsPerBar
            let bassStrength = bass.isEmpty ? 0 : Double(bass.strength(at: time))
            let onsetStrength = Double(onsets.strength(at: time))
            scores[phase] += bassStrength + 0.5 * onsetStrength
            counts[phase] += 1
        }
        for phase in scores.indices where counts[phase] > 0 {
            scores[phase] /= counts[phase]
        }
        guard let best = scores.max(), best > 0,
              let phase = scores.firstIndex(of: best) else { return (0, 0) }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return (phase, min(1, max(0, (best - mean) / best)))
    }

    // MARK: - Whole pipeline

    /// Runs the whole analysis and returns a grid, or `nil` when the stem holds
    /// nothing periodic enough to place beats in at all.
    ///
    /// `Task.checkCancellation` is called between stages, which is as prompt as
    /// this gets: no single stage of a four-minute song runs for long, and the
    /// two that read files are the long ones.
    static func analyze(
        primaryURL: URL,
        bassURL: URL?,
        duration: TimeInterval,
        beatsPerBar: Int = 4,
        sourceStems: [StemKind] = [],
        report: @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> BeatGrid? {
        await report(0.05, "Reading the rhythm track…")
        let onsets = try onsetEnvelope(fileURL: primaryURL)
        try Task.checkCancellation()
        guard !onsets.isEmpty else { return nil }

        await report(0.4, "Looking for the bass…")
        let bass: OnsetEnvelope
        if let bassURL {
            bass = try onsetEnvelope(fileURL: bassURL, band: bassBand)
        } else {
            bass = OnsetEnvelope(values: [], hopSeconds: onsets.hopSeconds)
        }
        try Task.checkCancellation()

        await report(0.7, "Estimating the tempo…")
        guard let estimate = estimateTempo(envelope: onsets) else { return nil }
        let tempo = resolvedTempo(envelope: onsets, estimate: estimate)
        try Task.checkCancellation()

        await report(0.85, "Placing the beats…")
        let frames = trackBeats(envelope: onsets, bpm: tempo.bpm)
        guard frames.count > 2 else { return nil }
        let times = frames.map { refinedTime(ofFrame: $0, in: onsets) }
        try Task.checkCancellation()

        let phase = downbeatPhase(
            beatTimes: times,
            bass: bass,
            onsets: onsets,
            beatsPerBar: beatsPerBar
        )
        let support = beatSupport(times: times, envelope: onsets)
        var beats: [Beat] = []
        beats.reserveCapacity(times.count)
        for (index, time) in times.enumerated() {
            let isDownbeat = (index - phase.phase) % beatsPerBar == 0
            beats.append(Beat(time: time, isDownbeat: isDownbeat))
        }
        // Weighted towards the tempo, because a wrong tempo makes every beat
        // wrong while a wrong downbeat only makes the accents wrong.
        let tempoTerm = 0.55 * tempo.salience
        let supportTerm = 0.3 * support
        let phaseTerm = 0.15 * phase.confidence
        var grid = BeatGrid(
            beats: beats,
            beatsPerBar: beatsPerBar,
            confidence: tempoTerm + supportTerm + phaseTerm,
            sourceStems: sourceStems
        )
        grid.sanitize(duration: duration)
        await report(1, "Beat grid ready")
        return grid.isEmpty ? nil : grid
    }

    /// How strongly the placed beats actually coincide with onsets, 0 to 1.
    ///
    /// The dynamic program always returns *a* path, including through a song
    /// with no beats in it. This is the number that tells those apart.
    static func beatSupport(times: [TimeInterval], envelope: OnsetEnvelope) -> Double {
        guard !times.isEmpty else { return 0 }
        let total = times.reduce(0.0) { $0 + Double(envelope.strength(at: $1)) }
        return min(1, max(0, total / Double(times.count) / 1.5))
    }

    // MARK: - Reading

    static func windowSize(for sampleRate: Double) -> Int {
        let ideal = frameSeconds * max(8_000, sampleRate)
        let exponent = max(8, Int(log2(ideal).rounded()))
        return 1 << exponent
    }

    /// Streams a file into one mono float array.
    ///
    /// No resampling: the window and hop are derived from whatever rate the
    /// file is at, so every envelope comes out with the same time resolution
    /// without the whole-file stereo conversion the separators need.
    static func monoSamples(fileURL: URL) throws -> (values: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard file.length > 0, channelCount > 0, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            return ([], format.sampleRate)
        }
        var values = [Float]()
        values.reserveCapacity(Int(file.length))
        var scale = 1 / Float(channelCount)
        var mixed = [Float](repeating: 0, count: 65_536)

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            mixed.withUnsafeMutableBufferPointer { destination in
                guard let base = destination.baseAddress else { return }
                base.update(from: channels[0], count: frames)
                for channel in 1..<channelCount {
                    vDSP_vadd(base, 1, channels[channel], 1, base, 1, vDSP_Length(frames))
                }
                if channelCount > 1 {
                    vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frames))
                }
            }
            values.append(contentsOf: mixed[0..<frames])
        }
        return (values, format.sampleRate)
    }
}

/// A real-to-complex FFT with its scratch buffers, so the per-frame loop
/// allocates nothing.
///
/// Shared with `ChordDetector`, which needs exactly the same thing at a
/// different window length; there is no second copy of this.
///
/// Deliberately not `Sendable`: one instance belongs to one analysis pass, and
/// `vDSP_fft_zrip` writes through its split-complex buffers.
final class RealFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realParts: [Float]
    private var imaginaryParts: [Float]
    private var magnitudeStorage: [Float]

    /// The lower half of the spectrum, valid until the next `transform`.
    var magnitudes: [Float] { magnitudeStorage }

    init?(size: Int) {
        guard size >= 4, size & (size - 1) == 0 else { return nil }
        self.size = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        realParts = [Float](repeating: 0, count: size / 2)
        imaginaryParts = [Float](repeating: 0, count: size / 2)
        magnitudeStorage = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func transform(_ samples: [Float]) {
        let half = size / 2
        let setup = setup
        let log2n = log2n
        realParts.withUnsafeMutableBufferPointer { real in
            imaginaryParts.withUnsafeMutableBufferPointer { imaginary in
                guard let realBase = real.baseAddress,
                      let imaginaryBase = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imaginaryBase)
                samples.withUnsafeBufferPointer { input in
                    guard let base = input.baseAddress else { return }
                    base.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // `zrip` packs the Nyquist bin into `imagp[0]`. One bin at half
                // the sample rate says nothing about a drum hit, and unpacking
                // it would cost a special case in the flux loop.
                imaginaryBase[0] = 0
                self.magnitudeStorage.withUnsafeMutableBufferPointer { output in
                    guard let outputBase = output.baseAddress else { return }
                    vDSP_zvabs(&split, 1, outputBase, 1, vDSP_Length(half))
                    // `zrip` returns twice the mathematical transform.
                    var halfScale = Float(0.5)
                    vDSP_vsmul(outputBase, 1, &halfScale, outputBase, 1, vDSP_Length(half))
                }
            }
        }
    }
}
