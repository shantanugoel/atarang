import Foundation
import Darwin

enum ModelMemoryBudget {
    // HTDemucs 6-stem reports about 1.1 GB of steady-state runtime
    // memory, but native session construction has a substantially higher
    // transient peak. Keep enough room for decoded audio and the rest of
    // the foreground app as well.
    private static let sixStemMinimumAvailableBytes: UInt64 = 3 * 1_024 * 1_024 * 1_024

    static var supportsHTDemucs6Stem: Bool {
        availableBytes >= sixStemMinimumAvailableBytes
    }

    static var availableBytes: UInt64 {
        UInt64(os_proc_available_memory())
    }
}
