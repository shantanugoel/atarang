//
//  AtarangApp.swift
//  Atarang
//
//  Created by Shantanu Goel on 23/07/26.
//

import SwiftUI

@main
struct AtarangApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Nothing of ours can legitimately be staging at launch, so
                    // anything still there belongs to a run that was killed
                    // mid-commit.
                    await Task.detached(priority: .utility) {
                        LibraryStaging.sweepAbandonedStaging()
                        // Phase 5 moved every per-song value beside the song
                        // itself. Pre-release, so the keys earlier builds wrote
                        // are dropped rather than migrated.
                        SongStorage.purgeLegacyPerSongDefaults()
                    }.value
                }
        }
    }
}
