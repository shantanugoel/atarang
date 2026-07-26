#if DEBUG
import AVFoundation
import Foundation
import OSLog

/// A measurement harness for the Phase 0/1 physical-device pass.
///
/// The audio-layer claims that cannot be checked in the simulator are mostly
/// not perceptual — they are numbers nobody was printing. This turns them into
/// structured log lines:
///
/// - **Stem drift.** Every stem is converted from one shared node time, so the
///   spread between them is the synchronization the plan calls "an unverified
///   assumption underneath everything else in this phase".
/// - **Output latency.** What the position compensation is actually being fed
///   on real hardware, per route.
/// - **Tick gaps.** The position timer should fire every 100 ms; a gap while
///   the user scrolls is the run-loop-mode defect returning.
///
/// `DEBUG` only — this compiles out of a Release build entirely.
///
/// Read it from a terminal with
/// `xcrun devicectl device process launch --console --device <id> <bundle-id>`,
/// which forwards stdout. `log stream` has no device option on current macOS,
/// so `OSLog` alone is only readable through Console.app.
@MainActor
final class PlaybackDiagnostics {
    /// Gaps beyond this mean the timer stopped firing — 100 ms nominal plus
    /// generous slack for a busy main thread. Known caveat: iOS coalesces
    /// timers while the app is backgrounded, so gaps reported during
    /// background playback are the system's doing, not a defect.
    private static let tickGapThreshold: TimeInterval = 0.18
    /// Log a periodic sample this often so a quiet run still produces evidence.
    private static let sampleInterval: TimeInterval = 2

    private let logger = Logger(
        subsystem: "com.shantanugoel.atarang.Atarang",
        category: "Diagnostics"
    )
    private var lastTick: Date?
    private var lastSample = Date.distantPast
    private var worstDriftMilliseconds: Double = 0
    private var worstTickGap: TimeInterval = 0
    private var tickCount = 0

    /// Emits to both `OSLog` (for Console.app) and stdout.
    ///
    /// `log stream` cannot target a physical device on current macOS, so the
    /// only way to read these off the phone from a terminal is
    /// `devicectl device process launch --console`, which forwards stdout.
    private func emit(_ line: String) {
        logger.info("\(line, privacy: .public)")
        print("ATARANG-DIAG \(line)")
    }

    /// Clears the tick marker so the paused stretch that follows is not
    /// measured as a gap.
    func playbackStopped() {
        lastTick = nil
    }

    /// Called from the position timer. `reference` is one shared node time so
    /// every stem is measured against the same instant.
    func tick(
        activeStems: [StemKind],
        nodes: [StemKind: AVAudioPlayerNode],
        position: TimeInterval,
        isPlaying: Bool,
        outputLatency: TimeInterval
    ) {
        let now = Date()
        // Only measure gaps across continuous playback. A pause legitimately
        // invalidates the timer, so carrying `lastTick` across one reports the
        // whole paused stretch as a stall — which it is not.
        guard isPlaying else {
            lastTick = nil
            return
        }
        if let lastTick {
            let gap = now.timeIntervalSince(lastTick)
            if gap > worstTickGap { worstTickGap = gap }
            if gap > Self.tickGapThreshold {
                emit(String(format: "WARN tickGap=%.0fms — the position timer stalled", gap * 1000))
            }
        }
        lastTick = now
        tickCount += 1
        let drift = stemDriftMilliseconds(activeStems: activeStems, nodes: nodes)
        if let drift, drift > worstDriftMilliseconds { worstDriftMilliseconds = drift }

        guard now.timeIntervalSince(lastSample) >= Self.sampleInterval else { return }
        lastSample = now
        emit(
            String(
                format: "sample position=%.3fs drift=%@ms worstDrift=%.2fms latency=%.1fms worstTickGap=%.0fms",
                position,
                drift.map { String(format: "%.2f", $0) } ?? "n/a",
                worstDriftMilliseconds,
                outputLatency * 1000,
                worstTickGap * 1000
            )
        )
    }

    /// The spread, in milliseconds, between the stems' rendered positions.
    ///
    /// All stems start at one host time and are scheduled over the same source
    /// range, so a non-trivial spread here means they have come apart —
    /// exactly what the plan asks to confirm across seeks, pauses, route
    /// changes, interruptions, and repeated playback.
    private func stemDriftMilliseconds(
        activeStems: [StemKind],
        nodes: [StemKind: AVAudioPlayerNode]
    ) -> Double? {
        guard activeStems.count > 1,
              let reference = activeStems.lazy
                .compactMap({ nodes[$0]?.lastRenderTime })
                .first else { return nil }
        var elapsed: [Double] = []
        for stem in activeStems {
            guard let playerTime = nodes[stem]?.playerTime(forNodeTime: reference),
                  playerTime.sampleRate > 0 else { continue }
            elapsed.append(Double(playerTime.sampleTime) / playerTime.sampleRate)
        }
        guard let low = elapsed.min(), let high = elapsed.max(), elapsed.count > 1 else {
            return nil
        }
        return (high - low) * 1_000
    }

    /// Records a transport or session event, with the route and latency that
    /// were in force when it happened.
    func event(_ name: String, detail: String = "") {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map(\.portType.rawValue)
            .joined(separator: ",")
        let inputs = session.currentRoute.inputs
            .map(\.portType.rawValue)
            .joined(separator: ",")
        emit(
            String(
                format: "event=%@ %@ out=[%@] in=[%@] outputLatency=%.1fms ioBuffer=%.1fms sr=%.0f",
                name,
                detail,
                outputs.isEmpty ? "none" : outputs,
                inputs.isEmpty ? "none" : inputs,
                session.outputLatency * 1000,
                session.ioBufferDuration * 1000,
                session.sampleRate
            )
        )
    }

    /// Prints and clears the running worst-case figures, so each leg of the
    /// test sequence can be judged on its own.
    func summarize(_ label: String) {
        emit(
            String(
                format: "SUMMARY %@ ticks=%d worstDrift=%.2fms worstTickGap=%.0fms",
                label,
                tickCount,
                worstDriftMilliseconds,
                worstTickGap * 1000
            )
        )
        worstDriftMilliseconds = 0
        worstTickGap = 0
        tickCount = 0
    }
}
#endif
