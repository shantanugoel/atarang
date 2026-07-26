import AVFoundation
import XCTest
@testable import Atarang

/// Guards the assumption `StemPlayer.setPlaybackRate` now depends on: that
/// speed can be changed on a running graph, and that the player node's frame
/// count keeps describing the position in the song when it does.
///
/// If either half stopped being true, changing speed mid-playback would either
/// do nothing or make the playhead jump, and neither failure is visible in a
/// test that only exercises `PlaybackState` arithmetic.
final class LiveRateChangeTests: XCTestCase {
    private var engine: AVAudioEngine!
    private var player: AVAudioPlayerNode!
    private var timePitch: AVAudioUnitTimePitch!
    private var format: AVAudioFormat!

    override func setUpWithError() throws {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        // Render offline so the test does not depend on audio hardware being
        // available, and so 20 seconds of playback takes milliseconds.
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: 4_096
        )
        try engine.start()
    }

    override func tearDownWithError() throws {
        engine.stop()
        engine = nil
    }

    func testRateAppliesToARunningGraphAndFramesStayInSongTime() throws {
        let buffer = Self.silence(seconds: 30, format: format)
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()

        // Two seconds of output at 1.0× consumes two seconds of the file. The
        // tolerance is loose because the time-pitch unit pulls its input ahead
        // of the output it has produced, so the node always leads by a fraction
        // of a second; the delta below is the part that has to be exact.
        try render(seconds: 2)
        let atFullSpeed = try XCTUnwrap(playerSeconds())
        XCTAssertEqual(atFullSpeed, 2, accuracy: 0.2)

        // Change speed without stopping anything.
        timePitch.rate = 0.5
        try render(seconds: 2)
        let afterSlowing = try XCTUnwrap(playerSeconds())

        // Two more seconds of output now consume only one second of the file,
        // and the node's frame count reflects that: it counts song time, not
        // wall time, which is exactly why `calculatedPosition` must not scale
        // it by the rate a second time.
        XCTAssertEqual(afterSlowing - atFullSpeed, 1, accuracy: 0.05)
    }

    /// Renders `seconds` of output through the offline graph.
    private func render(seconds: Double) throws {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let output = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        )!
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, output.frameCapacity)
            let status = try engine.renderOffline(chunk, to: output)
            guard status == .success else {
                XCTFail("Offline render returned \(status.rawValue)")
                return
            }
            remaining -= chunk
        }
    }

    /// Seconds of source audio the player node has produced.
    private func playerSeconds() -> Double? {
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private static func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}
