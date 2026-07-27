import XCTest
@testable import Atarang

final class BeatGridTests: XCTestCase {
    private func steady(
        bpm: Double = 120,
        firstDownbeat: TimeInterval = 0,
        beatsPerBar: Int = 4,
        duration: TimeInterval = 60
    ) -> BeatGrid {
        BeatGrid.uniform(
            bpm: bpm,
            firstDownbeat: firstDownbeat,
            beatsPerBar: beatsPerBar,
            duration: duration
        )
    }

    func testAUniformGridCoversTheSongAtTheRequestedTempo() {
        let grid = steady(bpm: 120, duration: 10)

        XCTAssertEqual(grid.beats.count, 21)
        XCTAssertEqual(grid.bpm, 120)
        XCTAssertEqual(grid.beats.first?.time, 0)
        XCTAssertEqual(grid.beats.last?.time ?? 0, 10, accuracy: 0.0001)
    }

    func testBeatsBeforeTheFirstDownbeatAreKept() {
        // A song whose downbeat is at 1.4 s still has a pickup, and a grid that
        // began at the downbeat would leave the click silent through it.
        let grid = steady(bpm: 120, firstDownbeat: 1.4, duration: 10)

        XCTAssertEqual(grid.beats.first?.time ?? 0, 0.4, accuracy: 0.0001)
        XCTAssertEqual(grid.firstDownbeat ?? 0, 1.4, accuracy: 0.0001)
    }

    func testEveryBarLengthMarksItsOwnDownbeats() {
        let waltz = steady(bpm: 180, beatsPerBar: 3, duration: 4)

        XCTAssertEqual(waltz.downbeatTimes.count, 5)
        XCTAssertEqual(waltz.downbeatTimes.first, 0)
        XCTAssertEqual(waltz.downbeatTimes[1], 1, accuracy: 0.0001)
    }

    func testTempoIsTheMedianIntervalSoOneMissedBeatDoesNotMoveIt() {
        // Half-second beats with one beat missing in the middle. A mean would
        // report 111 BPM; the median reports the tempo that is actually there.
        var grid = BeatGrid(
            beats: [0, 0.5, 1, 2, 2.5, 3, 3.5].map { Beat(time: $0) },
            beatsPerBar: 4
        )
        grid.sanitize(duration: 10)

        XCTAssertEqual(grid.bpm, 120)
        XCTAssertTrue(grid.hasTempoDrift)
    }

    func testASteadyGridDoesNotClaimToDrift() {
        XCTAssertFalse(steady().hasTempoDrift)
    }

    func testSnappingMovesATimeOntoTheNearestBar() {
        let grid = steady(bpm: 120, duration: 60)

        // Bars every two seconds at 120 in four.
        XCTAssertEqual(grid.snapped(7.4, to: .bar), 8, accuracy: 0.0001)
        XCTAssertEqual(grid.snapped(6.6, to: .bar), 6, accuracy: 0.0001)
        XCTAssertEqual(grid.snapped(7.4, to: .beat), 7.5, accuracy: 0.0001)
    }

    func testAnUnreliableGridSnapsNothing() {
        var grid = steady()
        grid.isUserEdited = false
        grid.confidence = 0.1

        XCTAssertFalse(grid.isReliable)
        XCTAssertEqual(grid.snapped(7.4, to: .bar), 7.4)
    }

    func testAUserEditedGridIsTrustedWhateverTheDetectorThought() {
        var grid = steady()
        grid.confidence = 0
        grid.isUserEdited = true

        XCTAssertTrue(grid.isReliable)
    }

    func testCorrectingTheTempoReplacesTheBeatsAndKeepsTheDownbeat() {
        let detected = steady(bpm: 128, firstDownbeat: 0.75, duration: 30)

        let corrected = detected.settingTempo(96, duration: 30)

        XCTAssertEqual(corrected.bpm, 96)
        XCTAssertEqual(corrected.firstDownbeat ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertTrue(corrected.isUserEdited)
    }

    func testMovingTheDownbeatKeepsEveryBeatWhereItWas() {
        let grid = steady(bpm: 120, duration: 10)

        let moved = grid.settingFirstDownbeat(at: 1.4)

        XCTAssertEqual(moved.beats.map(\.time), grid.beats.map(\.time))
        // 1.4 is not a beat; the nearest one is 1.5.
        XCTAssertEqual(moved.firstDownbeat ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(moved.downbeatTimes[1], 3.5, accuracy: 0.0001)
        XCTAssertTrue(moved.isUserEdited)
    }

    func testChangingTheBarLengthKeepsTheBeatsAndTheDownbeat() {
        let grid = steady(bpm: 120, firstDownbeat: 1, duration: 10)

        let three = grid.settingBeatsPerBar(3)

        XCTAssertEqual(three.beatsPerBar, 3)
        XCTAssertEqual(three.beats.map(\.time), grid.beats.map(\.time))
        XCTAssertEqual(three.firstDownbeat ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(three.downbeatTimes[1], 2.5, accuracy: 0.0001)
    }

    func testAWrongGridIsCorrectableInThreeInteractions() {
        // The acceptance criterion, as a test: tempo, downbeat, bar length.
        var grid = steady(bpm: 128, duration: 30)

        grid = grid.settingTempo(96, duration: 30)
        grid = grid.settingFirstDownbeat(at: 0.6)
        grid = grid.settingBeatsPerBar(3)

        XCTAssertEqual(grid.bpm, 96)
        XCTAssertEqual(grid.beatsPerBar, 3)
        XCTAssertEqual(grid.firstDownbeat ?? 0, 0.625, accuracy: 0.0001)
        XCTAssertTrue(grid.isReliable)
    }

    func testReanalysisKeepsACorrectedGridAndReplacesADetectedOne() {
        let corrected = steady(bpm: 96)
        var detected = steady(bpm: 128)
        detected.isUserEdited = false
        let fresh = steady(bpm: 140)

        XCTAssertEqual(corrected.resolvingReanalysis(fresh).bpm, 96)
        XCTAssertEqual(detected.resolvingReanalysis(fresh).bpm, 140)
    }

    func testSanitizeSortsClampsAndDropsDuplicates() {
        var grid = BeatGrid(
            beats: [
                Beat(time: 2),
                Beat(time: 0.5, isDownbeat: true),
                Beat(time: 2.01),
                Beat(time: -1),
                Beat(time: 99),
                Beat(time: .nan),
            ],
            beatsPerBar: 27
        )

        grid.sanitize(duration: 10)

        XCTAssertEqual(grid.beats.map(\.time), [0.5, 2])
        XCTAssertEqual(grid.beatsPerBar, 12)
        XCTAssertEqual(grid.downbeatTimes, [0.5])
    }

    func testADuplicateDownbeatMarkSurvivesDeduplication() {
        var grid = BeatGrid(beats: [Beat(time: 2), Beat(time: 2.01, isDownbeat: true)])

        grid.sanitize(duration: 10)

        XCTAssertEqual(grid.beats.count, 1)
        XCTAssertTrue(grid.beats[0].isDownbeat)
    }

    func testAGridWithNoBeatsIsEmptyRatherThanBroken() {
        var grid = BeatGrid(beats: [Beat(time: 1)])
        grid.sanitize(duration: 10)

        XCTAssertTrue(grid.isEmpty)
        XCTAssertFalse(grid.isReliable)
        XCTAssertNil(grid.bpm)
    }
}

final class BeatDetectorTests: XCTestCase {
    private let sampleRate = 22_050.0

    /// A click track: one short burst of noise per beat, silence between.
    /// Enough to exercise the whole pipeline without an audio file.
    private func clickTrack(
        bpm: Double,
        seconds: Double,
        accentEvery: Int? = nil,
        offset: Double = 0
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let interval = 60 / bpm
        var beat = 0
        var generator = SystemRandomNumberGenerator()
        while true {
            let time = offset + Double(beat) * interval
            if time >= seconds { break }
            let start = Int(time * sampleRate)
            let length = Int(0.02 * sampleRate)
            let isAccent = accentEvery.map { beat % $0 == 0 } ?? false
            let gain: Float = isAccent ? 1 : 0.5
            for offset in 0..<length where samples.indices.contains(start + offset) {
                let envelope = Float(length - offset) / Float(length)
                let noise = Float.random(in: -1...1, using: &generator)
                samples[start + offset] = noise * envelope * gain
            }
            beat += 1
        }
        return samples
    }

    func testTempoIsFoundOnASteadyClickTrack() {
        let envelope = BeatDetector.onsetEnvelope(
            samples: clickTrack(bpm: 120, seconds: 20),
            sampleRate: sampleRate
        )

        let tempo = BeatDetector.estimateTempo(envelope: envelope)

        XCTAssertNotNil(tempo)
        XCTAssertEqual(tempo?.bpm ?? 0, 120, accuracy: 1.5)
        XCTAssertGreaterThan(tempo?.salience ?? 0, 0.3)
    }

    func testAnUnusualTempoIsFoundRatherThanPulledToThePrior() {
        let envelope = BeatDetector.onsetEnvelope(
            samples: clickTrack(bpm: 76, seconds: 25),
            sampleRate: sampleRate
        )

        let tempo = BeatDetector.estimateTempo(envelope: envelope)

        XCTAssertEqual(tempo?.bpm ?? 0, 76, accuracy: 2)
    }

    /// A backbeat with hi-hats on every eighth: the pattern that makes
    /// autocorrelation report double tempo, and most of popular music.
    private func rockPattern(bpm: Double, seconds: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds*sampleRate))
        let beat = 60 / bpm
        var generator = SystemRandomNumberGenerator()
        var index = 0
        while Double(index) * beat / 2 < seconds {
            let time = Double(index) * beat / 2
            let isBeat = index % 2 == 0
            let start = Int(time * sampleRate)
            let length = Int((isBeat ? 0.12 : 0.04) * sampleRate)
            for offset in 0..<length where samples.indices.contains(start + offset) {
                let t = Double(offset) / sampleRate
                let envelope = Float(exp(-(isBeat ? 18 : 90) * t))
                let value = isBeat
                    ? Float(sin(2 * .pi * 120 * exp(-18 * t) * t))
                    : Float.random(in: -1...1, using: &generator)
                samples[start + offset] += value * envelope * (isBeat ? 1 : 0.35)
            }
            index += 1
        }
        return samples
    }

    func testEighthNoteHiHatsDoNotDoubleTheTempo() {
        let envelope = BeatDetector.onsetEnvelope(
            samples: rockPattern(bpm: 100, seconds: 24),
            sampleRate: sampleRate
        )

        let raw = BeatDetector.estimateTempo(envelope: envelope)
        let resolved = BeatDetector.resolvedTempo(
            envelope: envelope,
            estimate: raw ?? BeatDetector.TempoEstimate(bpm: 0, salience: 0)
        )

        XCTAssertEqual(resolved.bpm, 100, accuracy: 3)
    }

    func testASongGenuinelyAtOneHundredIsNotHalved() {
        // The backbeat alternates too — kick against snare — so the halving
        // rule must not fire on a tempo that was never doubled.
        let envelope = BeatDetector.onsetEnvelope(
            samples: clickTrack(bpm: 100, seconds: 20),
            sampleRate: sampleRate
        )
        let estimate = BeatDetector.TempoEstimate(bpm: 100, salience: 0.8)

        XCTAssertEqual(
            BeatDetector.resolvedTempo(envelope: envelope, estimate: estimate).bpm,
            100
        )
    }

    func testBeatsLandOnTheClicksTheyWerePlacedFrom() {
        let bpm = 100.0
        let offset = 0.31
        let envelope = BeatDetector.onsetEnvelope(
            samples: clickTrack(bpm: bpm, seconds: 20, offset: offset),
            sampleRate: sampleRate
        )
        let frames = BeatDetector.trackBeats(envelope: envelope, bpm: bpm)
        let times = frames.map { BeatDetector.refinedTime(ofFrame: $0, in: envelope) }

        XCTAssertGreaterThan(times.count, 25)
        let interval = 60 / bpm
        // Every placed beat is within 15 ms of a real click — the acceptance
        // criterion, measured against a track whose beats are known exactly.
        for time in times {
            let nearest = (time - offset) / interval
            let error = abs(nearest - nearest.rounded()) * interval
            XCTAssertLessThan(error, 0.015, "beat at \(time) is \(error * 1000) ms out")
        }
    }

    func testSilenceProducesNoConfidentGrid() async throws {
        let envelope = BeatDetector.onsetEnvelope(
            samples: [Float](repeating: 0, count: Int(10 * sampleRate)),
            sampleRate: sampleRate
        )

        let tempo = BeatDetector.estimateTempo(envelope: envelope)
        let support = BeatDetector.beatSupport(
            times: stride(from: 0.0, to: 10.0, by: 0.5).map { $0 },
            envelope: envelope
        )

        XCTAssertEqual(support, 0)
        // Silence has no salient period; whatever tempo comes back must not be
        // presented as a fact.
        XCTAssertLessThan(tempo?.salience ?? 0, BeatGrid.reliableConfidence)
    }

    func testTheDownbeatFallsOnTheAccentedBeat() {
        let samples = clickTrack(bpm: 120, seconds: 20, accentEvery: 4)
        let envelope = BeatDetector.onsetEnvelope(samples: samples, sampleRate: sampleRate)
        let beatTimes = stride(from: 0.0, to: 19.0, by: 0.5).map { $0 }

        let phase = BeatDetector.downbeatPhase(
            beatTimes: beatTimes,
            bass: envelope,
            onsets: envelope,
            beatsPerBar: 4
        )

        XCTAssertEqual(phase.phase, 0)
        XCTAssertGreaterThan(phase.confidence, 0.1)
    }

    func testTheWindowIsAboutTwentyMillisecondsAtEveryRate() {
        XCTAssertEqual(BeatDetector.windowSize(for: 44_100), 1_024)
        XCTAssertEqual(BeatDetector.windowSize(for: 48_000), 1_024)
        XCTAssertEqual(BeatDetector.windowSize(for: 22_050), 512)
    }
}

final class CountInPlanTests: XCTestCase {
    func testClicksAreExactMultiplesOfTheBeat() {
        let plan = CountInPlan(clicks: 4, bpm: 90)

        XCTAssertEqual(plan.offsets.count, 4)
        XCTAssertEqual(plan.duration, 4 * 60 / 90, accuracy: 0.0000001)
        for (index, offset) in plan.offsets.enumerated() {
            XCTAssertEqual(offset, Double(index) * 60 / 90, accuracy: 0.0000001)
        }
    }

    func testTheCountInFollowsTheSongsTempoRatherThanTheClock() {
        XCTAssertEqual(CountInPlan(clicks: 4, bpm: 140).duration, 240 / 140, accuracy: 0.0001)
        XCTAssertEqual(CountInPlan(clicks: 4, bpm: 60).duration, 4, accuracy: 0.0001)
    }

    func testNonsenseTempiAreClampedRatherThanTrusted() {
        XCTAssertEqual(CountInPlan(clicks: 2, bpm: .nan).bpm, 120)
        XCTAssertEqual(CountInPlan(clicks: 2, bpm: 0).bpm, 30)
        XCTAssertEqual(CountInPlan(clicks: 2, bpm: 10_000).bpm, 300)
    }

    func testNoCountInIsEmptyAndCostsNoTime() {
        let plan = CountInPlan(clicks: 0, bpm: 120)

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.duration, 0)
        XCTAssertTrue(plan.offsets.isEmpty)
    }
}
