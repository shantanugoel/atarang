import Accelerate
import AVFoundation
import Foundation

/// A song's pitch-class energy over time.
///
/// Twelve numbers per frame, each frame normalised so its loudest pitch class is
/// 1. Normalising per frame is what lets one threshold work across a quiet verse
/// and a loud chorus: harmony is about which notes are sounding relative to each
/// other, not how loud the band was playing them.
struct Chromagram: Sendable, Equatable {
    /// Twelve values per frame, index 0 = C.
    var frames: [[Float]]
    var hopSeconds: Double
    /// The unnormalised loudness of each frame, kept so a silent stretch can be
    /// told from a stretch where nothing fits.
    var energies: [Float]

    var isEmpty: Bool { frames.isEmpty }

    func frame(at time: TimeInterval) -> Int {
        guard hopSeconds > 0 else { return 0 }
        return Int((time / hopSeconds).rounded(.down))
    }

    /// The mean chroma over a time range, with the range's mean energy.
    ///
    /// This is the beat-synchronous step: averaging within a beat is what turns
    /// a picture of every pluck and cymbal into a picture of the harmony, and it
    /// reduces a four-minute song to a few hundred vectors to decode.
    func mean(from start: TimeInterval, to end: TimeInterval) -> (chroma: [Float], energy: Float) {
        let first = max(0, frame(at: start))
        let last = min(frames.count - 1, frame(at: end))
        guard first <= last, !frames.isEmpty else {
            return ([Float](repeating: 0, count: 12), 0)
        }
        var total = [Float](repeating: 0, count: 12)
        var energy: Float = 0
        for index in first...last {
            for pitch in 0..<12 { total[pitch] += frames[index][pitch] }
            energy += energies[index]
        }
        let count = Float(last - first + 1)
        return (total.map { $0 / count }, energy / count)
    }
}

/// Finds a song's chords with no model and no download.
///
/// The pipeline is the standard one, and standard on purpose — every stage has a
/// published reference and a known failure mode, which matters for output the
/// user is invited to correct:
///
/// 1. an analysis mix built from the harmonic stems, so vocals and drums do not
///    vote on the harmony;
/// 2. a harmonic pitch-class profile with overtone suppression, plus a separate
///    chroma of the bass stem's own register;
/// 3. chroma averaged within each beat of the Phase 7 grid;
/// 4. cosine similarity against chord templates, with a bass term;
/// 5. a Viterbi decode over an HMM whose transitions favour staying put and
///    favour the key;
/// 6. Krumhansl–Schmuckler for the key, cross-checked against what was decoded.
///
/// Everything here is `nonisolated` and works on plain arrays, so it can be
/// tested against a synthetic progression without an audio engine.
enum ChordDetector {
    /// Harmony lives below 5 kHz; everything above it is cymbals and air. Half
    /// the CD rate is the usual working rate for chroma and halves every cost.
    static let sampleRate = 22_050.0
    /// 186 ms at 22.05 kHz. Long windows are what chroma wants — a chord is a
    /// steady state, and the bin spacing at the bottom of the range is the
    /// binding constraint, not time resolution.
    static let windowSize = 4_096
    static let hopSize = 1_024
    /// The register the profile is built from. Below A1 the bins are too coarse
    /// to separate semitones; above 5 kHz there is nothing but noise and the
    /// tenth harmonic of things already counted.
    static let harmonicBand: ClosedRange<Double> = 55...5_000
    /// Where a bass note lives. The point of the bass chroma is that it is *not*
    /// the rest of the arrangement.
    static let bassBand: ClosedRange<Double> = 40...250
    /// How many harmonics of a candidate fundamental are folded back onto it,
    /// and how fast their say decays.
    static let harmonicCount = 4
    static let harmonicDecay: Float = 0.6

    /// What each stem contributes to the analysis mix.
    ///
    /// Vocals and drums are excluded outright: a sung melody note is not the
    /// harmony and frequently disagrees with it, and drums contribute broadband
    /// noise to every pitch class equally. Bass comes in at 0.8 because its
    /// fundamental would otherwise dominate a normalised profile and turn every
    /// chord into its own root.
    static let stemWeights: [StemKind: Float] = [
        .bass: 0.8,
        .other: 1,
        .guitar: 1,
        .piano: 1,
        .instrumental: 1,
    ]

    /// How much the bass agrees, as a share of the total score. Enough to break
    /// a tie between a chord and its relative minor — which share two of three
    /// notes and are told apart almost entirely by what the bass plays — and not
    /// enough to let a passing bass note rewrite the chord above it.
    static let bassWeight = 0.35
    /// What a chord must beat to be printed at all. Cosine similarity against a
    /// normalised template, so this is "fits about as well as noise would": a
    /// chroma with every pitch class equally loud scores exactly 0.5 against any
    /// triad, and a clean triad scores above 0.9.
    static let noChordScore = 0.62
    /// Below this a beat is silence rather than harmony nobody could name.
    static let silenceEnergy: Float = 0.0001
    /// The cost of changing chord, in the same units as the similarity scores.
    /// This is the self-transition prior: harmony is piecewise constant, and
    /// without a cost the decoder prints a different chord on every beat.
    static let changePenalty = 0.22
    /// The extra cost of changing to a chord whose notes are not all in the key.
    static let outOfKeyPenalty = 0.08
    /// The margin at which a winning template is called certain. Neighbouring
    /// chords share notes, so the raw gaps are small; this is what turns one
    /// into a number a person can read.
    static let confidenceMargin = 0.12

    // MARK: - Templates

    /// One decodable state: a chord, or no chord at all.
    struct ChordState: Hashable, Sendable {
        var chord: Chord?

        static let all: [ChordState] = {
            var states = (0..<12).flatMap { root in
                ChordQuality.allCases.map { ChordState(chord: Chord(root: root, quality: $0)) }
            }
            states.append(ChordState(chord: nil))
            return states
        }()
    }

    /// Unit-length binary templates, one per chord state, in the order of
    /// `ChordState.all`. Built once: 84 twelve-element vectors is nothing to
    /// hold and everything to recompute per frame.
    static let templates: [[Float]] = ChordState.all.map { state in
        guard let chord = state.chord else { return [Float](repeating: 0, count: 12) }
        var template = [Float](repeating: 0, count: 12)
        for pitch in chord.pitchClasses { template[pitch] = 1 }
        let norm = sqrt(template.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? template.map { $0 / norm } : template
    }

    // MARK: - Chroma

    /// Builds a chromagram from mono samples.
    ///
    /// Overtone suppression is the harmonic-sum form: only spectral *peaks*
    /// contribute, and each peak contributes to the pitch class of every
    /// fundamental it could be a harmonic of, with a decaying say. A plain
    /// bin-to-pitch-class histogram would credit a lone C to C, G, E, and B♭ in
    /// turn as its harmonics climbed, which is how a monophonic bass line ends
    /// up looking like a dominant seventh.
    static func chromagram(
        samples: [Float],
        sampleRate: Double,
        band: ClosedRange<Double> = harmonicBand,
        harmonics: Int = harmonicCount
    ) -> Chromagram {
        let size = windowSize
        let hop = hopSize
        let hopSeconds = Double(hop) / sampleRate
        guard samples.count > size, sampleRate > 0, let fft = RealFFT(size: size) else {
            return Chromagram(frames: [], hopSeconds: hopSeconds, energies: [])
        }

        let half = size / 2
        let lowestBin = max(1, Int(band.lowerBound * Double(size) / sampleRate))
        let highestBin = min(half - 2, Int(band.upperBound * Double(size) / sampleRate))
        guard lowestBin < highestBin else {
            return Chromagram(frames: [], hopSeconds: hopSeconds, energies: [])
        }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: size)
        var frames: [[Float]] = []
        var energies: [Float] = []
        let frameCount = max(0, samples.count / hop + 1)
        frames.reserveCapacity(frameCount)
        energies.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            // Frames are *centred* on their own timestamp, as the beat
            // detector's are. An uncentred frame describes the 186 ms that
            // follow it, so every frame in the last beat of a bar already
            // contains a third of the chord that comes next — which moves every
            // chord change a beat early, and did.
            let start = index * hop - size / 2
            for offset in 0..<size {
                let position = start + offset
                frame[offset] = samples.indices.contains(position)
                    ? samples[position] * window[offset]
                    : 0
            }
            fft.transform(frame)
            let magnitudes = fft.magnitudes

            var chroma = [Float](repeating: 0, count: 12)
            var energy: Float = 0
            for bin in lowestBin...highestBin {
                let magnitude = magnitudes[bin]
                energy += magnitude
                // Peaks only. Between the partials a spectrum is noise, and
                // noise spread over every bin is what flattens a chroma into
                // twelve equal numbers.
                guard magnitude > magnitudes[bin - 1], magnitude >= magnitudes[bin + 1] else {
                    continue
                }
                let frequency = Double(bin) * sampleRate / Double(size)
                var weight: Float = 1
                for harmonic in 1...max(1, harmonics) {
                    let fundamental = frequency / Double(harmonic)
                    guard fundamental >= band.lowerBound else { break }
                    let pitch = 12 * log2(fundamental / 440) + 69
                    guard pitch.isFinite else { break }
                    let pitchClass = PitchClass.normalized(Int(pitch.rounded()))
                    chroma[pitchClass] += magnitude * weight
                    weight *= harmonicDecay
                }
            }
            let peak = chroma.max() ?? 0
            frames.append(peak > 0 ? chroma.map { $0 / peak } : chroma)
            energies.append(energy / Float(highestBin - lowestBin + 1))
        }

        return Chromagram(frames: frames, hopSeconds: hopSeconds, energies: energies)
    }

    /// Averages a chromagram within each beat.
    ///
    /// One vector per beat, and the last beat's window runs to the beat after it
    /// so the final chord is not measured over a stretch of applause.
    static func beatAveraged(
        _ chroma: Chromagram,
        beatTimes: [TimeInterval]
    ) -> (chroma: [[Float]], energies: [Float]) {
        guard beatTimes.count > 1, !chroma.isEmpty else { return ([], []) }
        var vectors: [[Float]] = []
        var energies: [Float] = []
        vectors.reserveCapacity(beatTimes.count - 1)
        for index in 0..<(beatTimes.count - 1) {
            let mean = chroma.mean(from: beatTimes[index], to: beatTimes[index + 1])
            vectors.append(mean.chroma)
            energies.append(mean.energy)
        }
        return (vectors, energies)
    }

    // MARK: - Scoring

    /// How well each chord state fits one beat.
    ///
    /// Cosine similarity against the templates, plus a bass term that rewards
    /// the root being in the bass and, more weakly, any chord tone being there —
    /// which is what an inversion is. The no-chord state scores a constant, so
    /// it wins exactly when nothing fits better than noise would: a flat chroma
    /// scores 0.5 against any triad, and a clean one scores above 0.9.
    ///
    /// The bass term is *relative* — how much more the bass supports this chord
    /// than it supports the average chord — for two reasons. It is neutral when
    /// the bass says nothing, which would otherwise scale every chord down
    /// against the no-chord constant and print silence over a song with no bass
    /// stem. And it is a comparison between candidates, which is the only thing
    /// a bass note can honestly settle.
    static func scores(
        chroma: [Float],
        bass: [Float],
        energy: Float
    ) -> [Double] {
        let norm = sqrt(chroma.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0, energy > silenceEnergy else {
            // Silence. Everything scores below the no-chord constant.
            return ChordState.all.map { $0.chord == nil ? 1 : 0 }
        }
        let bassPeak = bass.max() ?? 0
        var agreements = [Double](repeating: 0, count: ChordState.all.count)
        var chordCount = 0
        for (index, state) in ChordState.all.enumerated() {
            guard let chord = state.chord else { continue }
            chordCount += 1
            guard bassPeak > 0 else { continue }
            let root = Double(bass[chord.root] / bassPeak)
            let inversion = chord.pitchClasses
                .dropFirst()
                .map { Double(bass[$0] / bassPeak) }
                .max() ?? 0
            agreements[index] = root + 0.5 * inversion
        }
        let meanAgreement = chordCount > 0
            ? agreements.reduce(0, +) / Double(chordCount)
            : 0

        return ChordState.all.enumerated().map { index, state in
            guard let chord = state.chord else { return noChordScore }
            var similarity: Double = 0
            let template = templates[index]
            for pitch in 0..<12 {
                similarity += Double(chroma[pitch] * template[pitch])
            }
            similarity /= Double(norm)
            return similarity
                + bassWeight * (agreements[index] - meanAgreement)
                + chord.quality.prior
        }
    }

    /// The bass note under a beat, when the bass states one clearly.
    ///
    /// Only a decisive peak counts. A bass line that is walking through a bar
    /// has no single note under it, and printing a slash chord for every passing
    /// tone would make the chart unreadable for the sake of being technically
    /// more complete.
    static func bassPitchClass(_ bass: [Float]) -> Int? {
        guard let peak = bass.max(), peak > 0 else { return nil }
        let normalised = bass.map { $0 / peak }
        guard let best = normalised.firstIndex(of: 1) else { return nil }
        let runnerUp = normalised.enumerated()
            .filter { $0.offset != best }
            .map(\.element)
            .max() ?? 0
        return runnerUp < 0.6 ? best : nil
    }

    // MARK: - Decoding

    /// Runs Viterbi over the beats.
    ///
    /// The HMM is deliberately simple: staying on a chord is free, changing
    /// costs `changePenalty`, and changing to something outside the key costs a
    /// little more. Because the only alternative to staying is "the best other
    /// state", each step is linear in the number of states rather than
    /// quadratic, which is what keeps a four-minute song's decode instant.
    ///
    /// The penalties live in the same units as the similarity scores rather than
    /// in log-probabilities. Cosine similarities are not calibrated likelihoods,
    /// so multiplying them by real transition probabilities would be arithmetic
    /// with no meaning behind it; a cost in score units is honest about being a
    /// tuned trade-off.
    static func decode(
        beatScores: [[Double]],
        key: MusicalKey?
    ) -> [Int] {
        guard let first = beatScores.first, !first.isEmpty else { return [] }
        let stateCount = first.count
        let outOfKey: [Double] = ChordState.all.map { state in
            guard let key, let chord = state.chord else { return 0 }
            return key.contains(chord) ? 0 : outOfKeyPenalty
        }

        var previous = first
        var backlinks: [[Int]] = []
        backlinks.reserveCapacity(beatScores.count)

        for time in 1..<beatScores.count {
            var best = -Double.infinity
            var bestState = 0
            var secondBest = -Double.infinity
            for state in 0..<stateCount where previous[state] > secondBest {
                if previous[state] > best {
                    secondBest = best
                    best = previous[state]
                    bestState = state
                } else {
                    secondBest = previous[state]
                }
            }

            var current = [Double](repeating: 0, count: stateCount)
            var links = [Int](repeating: 0, count: stateCount)
            for state in 0..<stateCount {
                // The best way in from somewhere else cannot come from this
                // state itself, which is what the runner-up is for.
                let elsewhere = state == bestState ? secondBest : best
                let elsewhereSource = state == bestState ? -1 : bestState
                let stay = previous[state]
                let change = elsewhere - changePenalty - outOfKey[state]
                if stay >= change || elsewhereSource < 0 {
                    current[state] = stay + beatScores[time][state]
                    links[state] = state
                } else {
                    current[state] = change + beatScores[time][state]
                    links[state] = elsewhereSource
                }
            }
            backlinks.append(links)
            previous = current
        }

        var path = [Int](repeating: 0, count: beatScores.count)
        var cursor = previous.indices.max { previous[$0] < previous[$1] } ?? 0
        path[path.count - 1] = cursor
        for time in stride(from: backlinks.count - 1, through: 0, by: -1) {
            cursor = backlinks[time][cursor]
            path[time] = cursor
        }
        return path
    }

    /// How certain the decoded state is on one beat, 0 to 1.
    ///
    /// The margin between the decoded state and the best state it is not, scaled
    /// so a clean triad reads as certain. Neighbouring chords share notes, so
    /// the raw margins are a few hundredths and mean nothing on their own.
    static func confidence(of state: Int, in scores: [Double]) -> Double {
        guard scores.indices.contains(state) else { return 0 }
        let rival = scores.enumerated()
            .filter { $0.offset != state }
            .map(\.element)
            .max() ?? 0
        return min(1, max(0, (scores[state] - rival) / confidenceMargin * 0.5 + 0.5))
    }

    // MARK: - Key

    /// Krumhansl and Schmuckler's key profiles, correlated against the song's
    /// average chroma over all 24 rotations.
    static let majorKeyProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ]
    static let minorKeyProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ]

    static func estimateKey(from chroma: [Float]) -> (key: MusicalKey, strength: Double)? {
        guard chroma.count == 12, chroma.contains(where: { $0 > 0 }) else { return nil }
        let values = chroma.map(Double.init)
        var best: (key: MusicalKey, score: Double)?
        var scores: [Double] = []
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorKeyProfile : majorKeyProfile
                let rotated = (0..<12).map { profile[PitchClass.normalized($0 - tonic)] }
                let score = correlation(values, rotated)
                scores.append(score)
                if best == nil || score > best!.score {
                    best = (MusicalKey(tonic: tonic, isMinor: isMinor), score)
                }
            }
        }
        guard let best else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let strength = best.score > 0
            ? min(1, max(0, (best.score - mean) / max(0.0001, best.score)))
            : 0
        return (best.key, strength)
    }

    /// Re-reads the key from what was actually decoded.
    ///
    /// The correlation above is a statement about which notes were played most;
    /// this is a statement about which chords were played, weighted by how long
    /// each was held. They usually agree, and when they do not it is because a
    /// song's melody sits in a mode its chords do not — in which case the chords
    /// are the better witness for a chart.
    static func keyFromChords(
        _ segments: [ChordSegment]
    ) -> (key: MusicalKey, strength: Double)? {
        let played = segments.filter { $0.chord != nil }
        let total = played.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return nil }
        var best: (key: MusicalKey, score: Double)?
        var scores: [Double] = []
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let key = MusicalKey(tonic: tonic, isMinor: isMinor)
                var score: Double = 0
                for segment in played {
                    guard let chord = segment.chord else { continue }
                    guard key.contains(chord) else { continue }
                    // The tonic and dominant carry a key far more than the
                    // other diatonic chords, which several keys share.
                    let degree = PitchClass.normalized(chord.root - key.tonic)
                    let weight = degree == 0 ? 1.5 : (degree == 7 ? 1.25 : 1)
                    score += segment.duration * weight
                }
                scores.append(score)
                if best == nil || score > best!.score {
                    best = (key, score)
                }
            }
        }
        guard let best, best.score > 0 else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        return (best.key, min(1, max(0, (best.score - mean) / best.score)))
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let leftMean = lhs.reduce(0, +) / Double(lhs.count)
        let rightMean = rhs.reduce(0, +) / Double(rhs.count)
        var covariance: Double = 0
        var leftVariance: Double = 0
        var rightVariance: Double = 0
        for index in lhs.indices {
            let left = lhs[index] - leftMean
            let right = rhs[index] - rightMean
            covariance += left * right
            leftVariance += left * left
            rightVariance += right * right
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 0 ? covariance / denominator : 0
    }

    // MARK: - Downbeats

    /// Which beat of the bar chord changes prefer.
    ///
    /// This is the evidence Phase 7 left for Phase 8 to supply: harmony changes
    /// on the one far more often than anywhere else, so the phase that collects
    /// the most changes is the phase the bar starts on.
    static func downbeatPhase(
        changeBeatIndices: [Int],
        beatsPerBar: Int
    ) -> (phase: Int, confidence: Double)? {
        guard beatsPerBar > 1, changeBeatIndices.count > beatsPerBar else { return nil }
        var counts = [Double](repeating: 0, count: beatsPerBar)
        for index in changeBeatIndices {
            counts[((index % beatsPerBar) + beatsPerBar) % beatsPerBar] += 1
        }
        guard let best = counts.max(), best > 0,
              let phase = counts.firstIndex(of: best) else { return nil }
        let mean = counts.reduce(0, +) / Double(counts.count)
        return (phase, min(1, max(0, (best - mean) / best)))
    }

    // MARK: - Reading

    /// Builds the analysis mix: the harmonic stems, mono, at 22.05 kHz.
    ///
    /// Returns which stems it actually used, so the result can say what it
    /// listened to rather than what it hoped for.
    static func analysisMix(
        files: [StemKind: URL]
    ) throws -> (samples: [Float], stems: [StemKind]) {
        let used = StemKind.allCases.filter { stemWeights[$0] != nil && files[$0] != nil }
        guard !used.isEmpty else { return ([], []) }
        var mix: [Float] = []
        for stem in used {
            guard let url = files[stem], var weight = stemWeights[stem] else { continue }
            try Task.checkCancellation()
            let samples = try monoSamples(fileURL: url, sampleRate: sampleRate)
            guard !samples.isEmpty else { continue }
            if mix.count < samples.count {
                mix.append(contentsOf: [Float](repeating: 0, count: samples.count - mix.count))
            }
            samples.withUnsafeBufferPointer { source in
                guard let base = source.baseAddress else { return }
                mix.withUnsafeMutableBufferPointer { destination in
                    guard let target = destination.baseAddress else { return }
                    vDSP_vsma(
                        base, 1, &weight, target, 1, target, 1,
                        vDSP_Length(samples.count)
                    )
                }
            }
        }
        return (mix, used)
    }

    /// Streams a file into one mono float array at `sampleRate`.
    ///
    /// Streamed rather than read whole and converted whole: a nine-minute stereo
    /// stem at 44.1 kHz is ninety megabytes before conversion, and the analysis
    /// holds two of these at once.
    static func monoSamples(fileURL: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        guard file.length > 0 else { return [] }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target),
           let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else {
            throw StemSeparatorError.unsupportedFormat
        }

        let supplier = try StreamingFileInput(file: file, chunkFrames: 16_384)
        var values: [Float] = []
        values.reserveCapacity(Int(Double(file.length) * sampleRate / file.processingFormat.sampleRate))

        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, status in
                supplier.supply(status)
            }
            if let conversionError {
                throw StemSeparatorError.inferenceFailed(conversionError.localizedDescription)
            }
            let frames = Int(output.frameLength)
            if frames > 0, let channel = output.floatChannelData?[0] {
                values.append(contentsOf: UnsafeBufferPointer(start: channel, count: frames))
            }
            if status == .endOfStream || status == .error { break }
            if status == .inputRanDry, frames == 0 { break }
        }
        return values
    }

    // MARK: - Whole pipeline

    struct Result: Sendable {
        var chords: SongChords
        /// What the chord changes say about where the bar starts, for the beat
        /// grid to take or leave.
        var downbeatPhase: Int?
        var downbeatConfidence: Double = 0
    }

    /// Runs the whole analysis, or returns `nil` when the separation holds
    /// nothing harmonic to listen to.
    ///
    /// `Task.checkCancellation` is called between stages and inside the file
    /// reads, which are the long ones.
    static func analyze(
        files: [StemKind: URL],
        grid: BeatGrid,
        duration: TimeInterval,
        report: @Sendable (Double, String) async -> Void = { _, _ in }
    ) async throws -> Result? {
        let beatTimes = grid.beats.map(\.time)
        guard beatTimes.count > 4 else { return nil }

        await report(0.05, "Building the analysis mix…")
        let mix = try analysisMix(files: files)
        guard !mix.samples.isEmpty else { return nil }
        try Task.checkCancellation()

        await report(0.35, "Listening for the bass…")
        let bassSamples = try files[.bass].map { try monoSamples(fileURL: $0, sampleRate: sampleRate) }
        try Task.checkCancellation()

        await report(0.5, "Measuring the notes…")
        let harmonic = chromagram(samples: mix.samples, sampleRate: sampleRate)
        guard !harmonic.isEmpty else { return nil }
        try Task.checkCancellation()

        // With no bass stem the bass register of the mix is the next best
        // witness. It is a worse one — the guitar's low strings are in it too —
        // which is why the result records what it listened to.
        let bassSource = bassSamples ?? mix.samples
        let bass = chromagram(
            samples: bassSource,
            sampleRate: sampleRate,
            band: bassBand,
            harmonics: 1
        )
        try Task.checkCancellation()

        await report(0.7, "Following the harmony…")
        let beatHarmonic = beatAveraged(harmonic, beatTimes: beatTimes)
        let beatBass = beatAveraged(bass, beatTimes: beatTimes)
        guard beatHarmonic.chroma.count > 1 else { return nil }

        let silentBass = [Float](repeating: 0, count: 12)
        let beatScores = beatHarmonic.chroma.indices.map { index in
            scores(
                chroma: beatHarmonic.chroma[index],
                bass: index < beatBass.chroma.count ? beatBass.chroma[index] : silentBass,
                energy: beatHarmonic.energies[index]
            )
        }

        var average = [Float](repeating: 0, count: 12)
        for vector in beatHarmonic.chroma {
            for pitch in 0..<12 { average[pitch] += vector[pitch] }
        }
        var key = estimateKey(from: average)?.key
        try Task.checkCancellation()

        var path = decode(beatScores: beatScores, key: key)
        var chords = assemble(
            path: path,
            beatScores: beatScores,
            beatTimes: beatTimes,
            beatBass: beatBass.chroma,
            duration: duration
        )

        // Cross-check: the chords that were actually decoded are a better
        // witness to the key than the average chroma, which is dominated by
        // whichever note the arrangement leans on. When they disagree, decode
        // once more with the chords' answer rather than trusting either alone.
        if let refined = keyFromChords(chords.segments), refined.key != key, refined.strength > 0.3 {
            key = refined.key
            path = decode(beatScores: beatScores, key: refined.key)
            chords = assemble(
                path: path,
                beatScores: beatScores,
                beatTimes: beatTimes,
                beatBass: beatBass.chroma,
                duration: duration
            )
        }

        await report(0.9, "Naming the chords…")
        chords.key = key
        chords.sourceStems = mix.stems

        // Where the bar starts, according to the harmony, before anything is
        // moved onto a bar line. Reading it after the alignment would be
        // circular: the alignment would have pushed the changes onto the grid's
        // existing phase, and they would then agree with it by construction.
        let changes = changeBeatIndices(in: path)
        let phase = downbeatPhase(changeBeatIndices: changes, beatsPerBar: grid.beatsPerBar)
        // Snapping is done against the phase this analysis believes in, so the
        // chart, the suggestion, and the grid the user ends up with all say the
        // same thing.
        let barGrid: BeatGrid
        if let phase, phase.confidence >= 0.25, !grid.isUserEdited {
            barGrid = grid.settingDownbeatPhase(phase.phase)
        } else {
            barGrid = grid
        }
        chords.segments = alignedToBars(chords.segments, grid: barGrid)
        chords.sanitize(duration: duration)
        chords.confidence = overallConfidence(of: chords)
        guard !chords.isEmpty else { return nil }

        await report(1, "Chords ready")
        return Result(
            chords: chords,
            downbeatPhase: phase?.phase,
            downbeatConfidence: phase?.confidence ?? 0
        )
    }

    /// Turns a decoded path into segments, one per beat, for `sanitize` to
    /// merge. Merging there rather than here keeps one rule for what a segment
    /// is, shared with corrections and re-analysis.
    static func assemble(
        path: [Int],
        beatScores: [[Double]],
        beatTimes: [TimeInterval],
        beatBass: [[Float]],
        duration: TimeInterval
    ) -> SongChords {
        var chords = SongChords()
        for (index, state) in path.enumerated() {
            guard index + 1 < beatTimes.count else { break }
            var chord = ChordState.all[state].chord
            if var value = chord, index < beatBass.count,
               let bass = bassPitchClass(beatBass[index]),
               bass != value.root,
               value.pitchClasses.contains(bass) {
                value.bass = bass
                chord = value
            }
            chords.segments.append(
                ChordSegment(
                    start: beatTimes[index],
                    end: beatTimes[index + 1],
                    chord: chord,
                    confidence: confidence(of: state, in: beatScores[index])
                )
            )
        }
        chords.sanitize(duration: duration)
        return chords
    }

    /// Pulls a boundary onto the bar line when it is a single beat away from
    /// one and the fragment it creates is shorter than a beat.
    ///
    /// This is the bar-snapping step, and it is deliberately narrow. A chord
    /// that genuinely changes a beat early — an anticipation, which is
    /// everywhere in popular music — is a real feature of the song and must
    /// survive; a one-beat fragment straddling a bar line is the decoder
    /// hedging, and it makes the grid unreadable.
    static func alignedToBars(_ segments: [ChordSegment], grid: BeatGrid) -> [ChordSegment] {
        guard grid.isReliable, segments.count > 1 else { return segments }
        guard let beat = grid.secondsPerBeat, beat > 0 else { return segments }
        var result = segments
        for index in 1..<result.count {
            let boundary = result[index].start
            guard let bar = grid.nearestBarTime(to: boundary) else { continue }
            let offset = abs(bar - boundary)
            guard offset > 0.001, offset <= beat * 1.05 else { continue }
            let fragment = min(
                result[index - 1].duration,
                result[index].duration
            )
            guard fragment <= beat * 1.05 else { continue }
            result[index - 1].end = bar
            result[index].start = bar
        }
        return result.filter { $0.duration > 0.01 }
    }

    /// Which beats a chord change landed on.
    static func changeBeatIndices(in path: [Int]) -> [Int] {
        guard !path.isEmpty else { return [] }
        return (1..<path.count).filter { path[$0] != path[$0 - 1] }
    }

    /// The whole song's confidence: the duration-weighted mean of its segments,
    /// with no-chord stretches counting as the failures they are.
    static func overallConfidence(of chords: SongChords) -> Double {
        let total = chords.segments.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let weighted = chords.segments.reduce(0.0) { sum, segment in
            sum + (segment.chord == nil ? 0 : segment.confidence) * segment.duration
        }
        return min(1, max(0, weighted / total))
    }
}

/// Feeds an `AVAudioConverter` from a file, one chunk at a time.
///
/// Synchronization invariant: `convert(to:error:withInputFrom:)` calls the input
/// block synchronously on the calling thread before it returns, and one instance
/// belongs to one conversion. The lock is there because the block is `@Sendable`
/// and so cannot capture mutable state directly, not because two threads are
/// expected.
private final class StreamingFileInput: @unchecked Sendable {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var isFinished = false

    init(file: AVAudioFile, chunkFrames: AVAudioFrameCount) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: chunkFrames
        ) else { throw StemSeparatorError.unsupportedFormat }
        self.file = file
        self.buffer = buffer
    }

    func supply(
        _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        guard buffer.frameLength > 0 else {
            isFinished = true
            status.pointee = .endOfStream
            return nil
        }
        status.pointee = .haveData
        return buffer
    }
}
