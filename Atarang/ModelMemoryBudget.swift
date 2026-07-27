import Foundation
import Darwin

enum ModelMemoryBudget {
    // HTDemucs 6-stem reports about 1.1 GB of steady-state runtime
    // memory, but native session construction has a substantially higher
    // transient peak. Keep enough room for decoded audio and the rest of
    // the foreground app as well.
    static let sixStemMinimumAvailableBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024

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
