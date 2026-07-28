import Foundation
import Darwin

enum ModelMemoryBudget {
    // HTDemucs 6-stem reports about 1.1 GB of steady-state runtime
    // memory, but native session construction has a substantially higher
    // transient peak. Keep enough room for decoded audio and the rest of
    // the foreground app as well.
    static let sixStemMinimumAvailableBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024

    /// MDX23C InstVoc HQ.
    ///
    /// Provisional. A user's run was observed at over 2.5 GB in use, which is
    /// the only measurement there is; the app's own share of that is now about
    /// 60 MB — one 16.8 MB spectrum, the model's 33.5 MB output, and the
    /// windows around them — so effectively all of it is Core ML holding
    /// activations for attention across 4,096 frequency bins. Two gigabytes is
    /// set below the observed figure deliberately: it blocks the devices that
    /// would be terminated part way through a long run without blocking the
    /// ones where it has been seen to work. Replace it with a measured peak.
    static let vocalHighQualityMinimumAvailableBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024

    /// Kim Vocal 2.
    ///
    /// Also provisional, and lower: three quarters of the frequency bins, a
    /// 12.6 MB spectrum, and ONNX on the CPU with its worker threads already
    /// capped at two. It runs the graph twice per chunk, but sequentially, so
    /// the second inference reuses the first one's arena rather than adding to
    /// it.
    static let vocalFocusedMinimumAvailableBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024 / 2

    static var supportsHTDemucs6Stem: Bool {
        hasHeadroom(forBytes: sixStemMinimumAvailableBytes)
    }

    /// Whether this much memory is free right now.
    ///
    /// The queue asks this when a job reaches the front rather than when it was
    /// submitted, so a job that waited minutes behind another is judged on the
    /// device it is about to run in.
    static func hasHeadroom(forBytes bytes: UInt64) -> Bool {
        availableBytes >= bytes
    }

    static var availableBytes: UInt64 {
        UInt64(os_proc_available_memory())
    }
}
