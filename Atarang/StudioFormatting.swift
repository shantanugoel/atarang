import Foundation

/// Formatting shared by the transport, the chips, and the stages, so the same
/// value never reads two ways on one screen.
enum StudioFormat {
    /// `m:ss`, clamped at zero. Deliberately not `Duration.formatted`: this
    /// appears in monospaced-digit readouts next to a moving playhead, and the
    /// locale-aware forms change width as they count.
    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    /// `m:ss.t` for values a user is nudging a tenth at a time.
    static func preciseTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00.0" }
        // Rounded to a tenth *before* the split, not by the format string
        // afterwards. Rounding last leaves 59.96 as "0:60.0" — the seconds
        // field showing a value that should have carried into the minute.
        let value = (max(0, seconds) * 10).rounded() / 10
        let minutes = Int(value) / 60
        let remainder = value - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }

    static func percent(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    static func bpm(_ value: Int) -> String { "\(value) BPM" }

    /// A playback rate, and what it means in the tempo the user is actually
    /// counting in. "75%" says how far a slider has moved; "75% · 96 BPM" says
    /// what the metronome will read, which is the number a practising musician
    /// works to. Falls back to the percentage alone when the song's tempo is
    /// unknown.
    static func rate(_ value: Float, atOriginalBPM originalBPM: Int?) -> String {
        guard let originalBPM, originalBPM > 0 else { return percent(value) }
        let scaled = Int((Double(originalBPM) * Double(value)).rounded())
        return "\(percent(value)) · \(bpm(scaled))"
    }

    static func semitones(_ semitones: Float) -> String {
        let value = Int(semitones.rounded())
        if value == 0 { return "Original key" }
        return "\(value > 0 ? "+" : "")\(value) semitone\(abs(value) == 1 ? "" : "s")"
    }

    /// The short form the chip row shows, where the chip is already labelled
    /// "Key".
    static func semitonesShort(_ semitones: Float) -> String {
        let value = Int(semitones.rounded())
        if value == 0 { return "Original" }
        return "\(value > 0 ? "+" : "")\(value)"
    }

    /// The shortest form, for the transport, where the row has to hold six
    /// controls and the note icon carries the meaning. Always paired with a
    /// spoken accessibility value.
    static func semitonesCompact(_ semitones: Float) -> String {
        let value = Int(semitones.rounded())
        return "\(value > 0 ? "+" : "")\(value)"
    }
}
